//  AppLister.swift
//  BatKill
//
//  Discovers all user-relevant software on the system: GUI applications,
//  launch agents, and background services. Maintains a persisted selection
//  list so the user's kill preferences survive restarts.
//
//  App discovery follows a 5-phase process:
//  1. Scan /Applications, ~/Applications, /System/Applications for .app bundles
//  2. Enumerate running apps not found in standard directories (via NSWorkspace)
//  3. Scan ~/Library/LaunchAgents/ for user launch agent plists
//  4. Query launchd for registered user-space services
//  5. Query Homebrew for all brew services (running or stopped)

import Cocoa
import Foundation

/// Enumerates user-installed apps, launch agents, and background services.
///
/// The `apps` array is the single source of truth for the entire UI and
/// the kill/restore logic. Each `AppItem` carries its runtime state
/// (running, PID), user selection, and category metadata.
///
/// Selection state is persisted in UserDefaults under `selectedAppPaths`
/// and restored on each `refreshAppList()` call.
final class AppLister: ObservableObject {
    /// The full discovered list of apps, sorted by running status then A-Z.
    @Published var apps: [AppItem] = []

    /// Whether a background scan is currently in progress.
    @Published var isLoading = false

    /// Whether at least one scan has completed (for initial UI state).
    @Published var hasLoaded = false

    /// UserDefaults key for the persisted set of selected app paths.
    private let selectedPathsKey = "selectedAppPaths"

    /// UserDefaults key for tracking known system paths (informational).
    private let isSystemPathsKey = "knownSystemPaths"

    /// UserDefaults key for per-app suspend strategy (path -> rawValue).
    private let suspendStrategyKey = "appSuspendStrategies"

    /// UserDefaults key for the last manual suspend-strategy update timestamp.
    /// Used to expire the temporary override (~30 days) so auto defaults are
    /// re-evaluated after a software update (CHANGE-061).
    private let suspendStrategySetAtKey = "appSuspendStrategiesSetAt"

    /// How long a temporary manual override stays valid before BatKill resets
    /// to auto defaults (30 days).
    private let suspendStrategyResetInterval: TimeInterval = 30 * 24 * 3600

    /// UserDefaults key for the set of currently `SIGSTOP`-frozen app paths.
    /// Shared with ProcessKiller (writer) -- AppLister reads it to hydrate
    /// `AppItem.isSuspended` for UI display.
    private let suspendedPathsKey = "suspendedPaths"

    // MARK: - Persisted Suspend Strategy

    /// Per-app suspend strategy map (path -> SuspendStrategy rawValue).
    /// Persisted to UserDefaults so each app's mode survives restarts.
    /// Missing entries fall back to the per-app auto default (`autoSuspendStrategy`).
    private var appSuspendStrategies: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: suspendStrategyKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: suspendStrategyKey) }
    }

    /// Timestamp of the last manual suspend-strategy update (or reset).
    /// Persisted so the temporary override expires across restarts.
    private var suspendStrategySetAt: Date {
        get { UserDefaults.standard.object(forKey: suspendStrategySetAtKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: suspendStrategySetAtKey) }
    }

    /// Set of app paths currently frozen via `SIGSTOP` (suspend mode).
    /// Read-only here; ProcessKiller owns writes.
    private var suspendedPathsSet: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: suspendedPathsKey) ?? [])
    }

    /// Resolves the suspend strategy for an app: the user's temporary override
    /// if present, else the per-app auto default (sequence: suspend -> graceful
    /// -> force, first supported).
    private func suspendStrategy(for app: AppItem) -> SuspendStrategy {
        appSuspendStrategies[app.path].flatMap(SuspendStrategy.init(rawValue:)) ?? app.autoSuspendStrategy
    }

    // MARK: - Persisted Selection

    /// Set of app paths that the user has checked in the settings UI.
    /// Persisted to UserDefaults so selections survive app restarts.
    private var selectedPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: selectedPathsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: selectedPathsKey) }
    }

    /// Read-only snapshot of the persisted selection (app paths). Exposed so
    /// the restore flow can match pending apps even after they have dropped
    /// out of the live `apps` list (e.g. non-standard-path apps that are only
    /// discovered while running).
    var selectedAppPaths: Set<String> { selectedPaths }

    // MARK: - Public API

    /// Triggers a full background scan of all app categories.
    /// Updates `apps` on the main thread when complete.
    /// Skips if a scan is already in progress to prevent overlapping results.
    func refreshAppList() {
        let ctx = LogContext(name: "refreshAppList")
        ctx.log("开始扫描应用列表")
        guard !isLoading else {
            ctx.debug("扫描已在进行中，跳过")
            return
        }
        isLoading = true
        hasLoaded = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let saved = self.selectedPaths
            let newApps = self.buildAppList(savedPaths: saved)

            ctx.complete(success: true, extra: "发现 \(newApps.count) 个应用")

            DispatchQueue.main.async {
                self.apps = newApps
                self.isLoading = false
                self.hasLoaded = true
            }
        }
    }

    /// Toggles the selection state of an app and persists the change.
    /// Mutates the array element to trigger `@Published` notification.
    func toggleApp(_ app: AppItem) {
        guard let idx = apps.firstIndex(where: { $0.id == app.id }) else { return }
        var mutable = apps[idx]
        mutable.isSelected.toggle()
        apps[idx] = mutable // replaces element -> triggers @Published

        let path = apps[idx].id
        var paths = selectedPaths
        if apps[idx].isSelected { paths.insert(path) } else { paths.remove(path) }
        selectedPaths = paths
    }

    /// Sets the suspend strategy for an app and persists it as a temporary
    /// user override. Mutates the array element to trigger `@Published`.
    /// The override is stored regardless of mode (no removal) and refreshes
    /// the expiry timestamp so the user's choice is respected for ~30 days.
    func setSuspendStrategy(_ mode: SuspendStrategy, for app: AppItem) {
        guard let idx = apps.firstIndex(where: { $0.id == app.id }) else { return }
        var mutable = apps[idx]
        mutable.suspendStrategy = mode
        apps[idx] = mutable // replaces element -> triggers @Published

        var strategies = appSuspendStrategies
        strategies[app.id] = mode.rawValue
        appSuspendStrategies = strategies
        suspendStrategySetAt = Date()
    }

    // MARK: - App Discovery (5-Phase Process)

    /// Whether a discovered app is BatKill itself.
    ///
    /// Self must never be a kill/suspend/restore candidate: suspending (CHANGE-005
    /// suspend mode) calls `kill(getpid(), SIGSTOP)`, which freezes the very
    /// process that has to send `SIGCONT` when AC returns — a permanent deadlock
    /// with no in-app way out (CHANGE-084).
    ///
    /// Pure so the rule is unit-testable without a live bundle.
    static func isSelfApp(_ path: String, bundleIdentifier: String?,
                          selfPath: String, selfBundleIdentifier: String?) -> Bool {
        if let id = bundleIdentifier, let selfID = selfBundleIdentifier,
           !id.isEmpty, id == selfID { return true }
        return !path.isEmpty && path == selfPath
    }

    /// Bundle-aware wrapper: BatKill is recognized both by its bundle identifier
    /// (`com.batkill.app`, covering an installed `/Applications/BatKill.app`) and
    /// by its own bundle path (covering a dev build such as
    /// `.build/arm64/BatKill-arm64.app`, whose path differs between builds).
    static func isSelfApp(path: String, bundleIdentifier: String?) -> Bool {
        isSelfApp(path, bundleIdentifier: bundleIdentifier,
                  selfPath: Bundle.main.bundlePath,
                  selfBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// Builds the complete app list by running all 5 discovery phases
    /// and merging results. Deduplicates by path, sorts by running
    /// status then alphabetically.
    private func buildAppList(savedPaths: Set<String>) -> [AppItem] {
        var seen = Set<String>()
        var result: [AppItem] = []
        let fm = FileManager.default

        // ── Phase 1: Scan standard Applications directories ──
        // Scans /Applications, ~/Applications, and /System/Applications
        // for .app bundles, reading display names and bundle identifiers.
        let appDirs: [(path: String, isSystem: Bool)] = [
            ("/Applications", false),
            (NSHomeDirectory() + "/Applications", false),
            ("/System/Applications", true)
        ]

        for (dir, isSystem) in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = "\(dir)/\(item)"
                guard seen.insert(fullPath).inserted else { continue }

                let bundle = Bundle(path: fullPath)
                // Never list BatKill itself — it cannot kill or restore
                // its own way out (CHANGE-084).
                if AppLister.isSelfApp(path: fullPath,
                                       bundleIdentifier: bundle?.bundleIdentifier) {
                    continue
                }
                let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (item as NSString).deletingPathExtension
                let bundleID = bundle?.bundleIdentifier
                let procName = bundle?.infoDictionary?["CFBundleExecutable"] as? String
                    ?? (item as NSString).deletingPathExtension
                let (running, pid) = self.appRuntimeInfo(path: fullPath, bundleID: bundleID)

                result.append(AppItem(
                    name: name,
                    bundleIdentifier: bundleID,
                    path: fullPath,
                    processName: procName,
                    isRunning: running,
                    isSelected: savedPaths.contains(fullPath),
                    isSystemApp: isSystem,
                    category: .application,
                    pid: pid
                ))
            }
        }

        // ── Phase 2: Running apps not in standard directories ──
        // Catches apps launched from non-standard locations (e.g., DMGs,
        // custom paths) that are currently running but weren't found in Phase 1.
        for app in NSWorkspace.shared.runningApplications {
            guard let path = app.bundleURL?.path,
                  let name = app.localizedName,
                  seen.insert(path).inserted else { continue }

            let isSystem = path.contains("/System/")
            // `runningApplications` always contains BatKill itself, so this
            // phase needs its own filter as well (CHANGE-084).
            if AppLister.isSelfApp(path: path,
                                   bundleIdentifier: app.bundleIdentifier) { continue }
            result.append(AppItem(
                name: name,
                bundleIdentifier: app.bundleIdentifier,
                path: path,
                processName: app.executableURL?.lastPathComponent ?? name,
                isRunning: true,
                isSelected: savedPaths.contains(path),
                isSystemApp: isSystem,
                category: .application,
                pid: app.processIdentifier
            ))
        }

        // ── Phase 3: Launch Agents (~/Library/LaunchAgents) ──
        // Scans for .plist files in the user's LaunchAgents directory.
        // Each plist represents a user-level launch agent that starts on login.
        let agentDir = NSHomeDirectory() + "/Library/LaunchAgents"
        if let contents = try? fm.contentsOfDirectory(atPath: agentDir) {
            for item in contents where item.hasSuffix(".plist") {
                let fullPath = "\(agentDir)/\(item)"
                guard seen.insert(fullPath).inserted else { continue }
                let name = (item as NSString).deletingPathExtension

                let (running, pid) = processRuntimeInfo(name)
                result.append(AppItem(
                    name: name,
                    bundleIdentifier: nil,
                    path: fullPath,
                    processName: name,
                    isRunning: running,
                    isSelected: savedPaths.contains(fullPath),
                    isSystemApp: false,
                    category: .launchAgent,
                    pid: pid
                ))
            }
        }

        // ── Phase 4: User launchd services ──
        // Queries `launchctl list gui/<uid>` for non-Apple services currently
        // registered with launchd. Filters out com.apple.* system services.
        let userServices = self.userLaunchdServices()
        for svc in userServices {
            let fullPath = "\(brewPrefix())/opt/\(svc.name)"
            guard seen.insert(fullPath).inserted else { continue }
            result.append(AppItem(
                name: svc.name,
                bundleIdentifier: nil,
                path: fullPath,
                processName: svc.name,
                isRunning: true,
                isSelected: savedPaths.contains(fullPath),
                isSystemApp: false,
                category: .service,
                pid: svc.pid,
                serviceLabel: svc.label
            ))
        }

        // ── Phase 5: Brew services (all, running or stopped) ──
        // Queries `brew services list` for all Homebrew-managed services,
        // including those that are currently stopped.
        let brewServices = self.brewAllServices()
        for svc in brewServices {
            let fullPath = "\(brewPrefix())/opt/\(svc.name)"
            guard seen.insert(fullPath).inserted else { continue }
            result.append(AppItem(
                name: svc.name,
                bundleIdentifier: nil,
                path: fullPath,
                processName: svc.name,
                isRunning: svc.isRunning,
                isSelected: savedPaths.contains(fullPath),
                isSystemApp: false,
                category: .service,
                pid: svc.pid,
                serviceLabel: svc.label
            ))
        }

        // ── Exclude core macOS system components (v0.2.4 CHANGE-060) ──
        // Core components (Dock, Finder, XPC helpers, ...) break core computer
        // function if managed, so they are filtered out of the discoverable /
        // killable list and never shown to the user.
        result = result.compactMap { app in
            if SystemCoreProtection.isCoreSystemComponent(
                path: app.path,
                bundleIdentifier: app.bundleIdentifier,
                processName: app.processName
            ) {
                return nil
            }
            return app
        }

        // ── Suspend strategy: expire + repair temporary overrides, then hydrate ──
        result = hydrateSuspendStrategies(result)

        // ── Sort: running apps first, then alphabetically ──
        result.sort { a, b in
            if a.isRunning != b.isRunning { return a.isRunning && !b.isRunning }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return result
    }

    /// Expires + repairs temporary per-app suspend-strategy overrides, then
    /// hydrates each app's strategy and suspended state (CHANGE-061).
    ///
    /// 1. A ~30-day-old manual override is reset so auto defaults re-evaluate
    ///    (following an app's capabilities after a software update).
    /// 2. Any stored mode the app no longer supports is downgraded per sequence.
    /// 3. Missing entries fall back to the per-app auto default (prefer suspend).
    private func hydrateSuspendStrategies(_ apps: [AppItem]) -> [AppItem] {
        if AppItem.isSuspendStrategyConfigExpired(lastSetAt: suspendStrategySetAt, now: Date(), interval: suspendStrategyResetInterval) {
            // First run after upgrading from a build without the timestamp key:
            // keep existing overrides but start the ~30-day countdown, instead of
            // wiping the user's manual choices on upgrade.
            if suspendStrategySetAt == .distantPast && !appSuspendStrategies.isEmpty {
                suspendStrategySetAt = Date()
            } else {
                if !appSuspendStrategies.isEmpty {
                    appSuspendStrategies = [:]
                }
                suspendStrategySetAt = Date()
            }
        }
        let repaired = AppItem.repairedStrategies(appSuspendStrategies, for: apps)
        if repaired != appSuspendStrategies {
            appSuspendStrategies = repaired
        }

        return apps.map { app in
            var hydrated = app
            hydrated.suspendStrategy = self.suspendStrategy(for: app)
            hydrated.isSuspended = self.suspendedPathsSet.contains(app.path)
            return hydrated
        }
    }

    // MARK: - Runtime Info Helpers

    /// Checks if an app is currently running by matching its bundle
    /// identifier or file path against `NSWorkspace.shared.runningApplications`.
    private func appRuntimeInfo(path: String, bundleID: String?) -> (Bool, Int32?) {
        for app in NSWorkspace.shared.runningApplications {
            if let bid = bundleID, let appBID = app.bundleIdentifier, appBID == bid {
                return (true, app.processIdentifier)
            }
            if app.bundleURL?.path == path {
                return (true, app.processIdentifier)
            }
        }
        return (false, nil)
    }

    /// Checks if a process is running by name using `pgrep -x` (exact match).
    /// Returns the PID if found, nil otherwise.
    private func processRuntimeInfo(_ name: String) -> (Bool, Int32?) {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", name]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return (false, nil) }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let pidStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = pidStr.flatMap({ Int32($0) }) {
            return (true, pid)
        }
        return (false, nil)
    }

    /// Returns user-space services currently registered with launchd,
    /// excluding Apple system services (com.apple.*).
    private func userLaunchdServices() -> [(name: String, label: String, pid: Int32)] {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", "gui/\(getuid())"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        var services: [(String, String, Int32)] = []

        for line in output.components(separatedBy: .newlines).dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // launchctl list format: PID    Status  Label
            if parts.count >= 3,
               let pid = Int32(parts[0]),
               parts[1] != "-",
               !parts[2].hasPrefix("com.apple.") { // skip Apple system services
                let label = parts[2]
                let name = label.components(separatedBy: ".").last ?? label
                services.append((name, label, pid))
            }
        }
        return services
    }

    /// Cached result of `brew --prefix`（v0.1.6 FIX-001：直调 brew 二进制，不经 shell）。
    private lazy var _brewPrefix: String = {
        guard let brew = ProcessRunner.brewPath(),
              let result = try? ProcessRunner.run(executable: brew,
                                                  arguments: ["--prefix"],
                                                  environment: ProcessRunner.defaultSearchEnvironment)
        else { return "" }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// Returns the Homebrew prefix for the current architecture.
    /// Uses `brew --prefix` once and caches the result.
    private func brewPrefix() -> String {
        _brewPrefix
    }

    /// Returns all brew services (running or stopped) via `brew services list`.
    /// For each service, also queries its PID via launchctl and pgrep.
    private func brewAllServices() -> [(name: String, label: String, isRunning: Bool, pid: Int32?)] {
        guard let brew = ProcessRunner.brewPath(),
              let result = try? ProcessRunner.run(executable: brew,
                                                  arguments: ["services", "list"],
                                                  environment: ProcessRunner.defaultSearchEnvironment)
        else { return [] }
        let output = result.output
        var services: [(String, String, Bool, Int32?)] = []

        for line in output.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let name = String(parts[0])
            guard !name.isEmpty else { continue }

            let label = "homebrew.mxcl.\(name)"
            let pid = self.brewServicePID(name)
            let isRunning = (pid ?? 0) > 0
            services.append((name, label, isRunning, pid))
        }
        return services
    }

    /// Gets the PID for a specific brew service by checking launchctl
    /// and falling back to pgrep. Has a special case for Colima's Docker
    /// socket (returns PID 1 if the socket exists, as the Docker daemon
    /// runs under a different process).
    private func brewServicePID(_ name: String) -> Int32? {
        let label = "homebrew.mxcl.\(name)"
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["list", label]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 1, let pid = Int32(parts[0]), pid > 0 {
                return pid
            }
        }

        // Fallback: try pgrep for exact process name match
        let pgrep = Process()
        pgrep.launchPath = "/usr/bin/pgrep"
        pgrep.arguments = ["-x", name]
        let pgrepOut = Pipe()
        pgrep.standardOutput = pgrepOut
        pgrep.standardError = Pipe()
        guard (try? pgrep.run()) != nil else { return nil }
        pgrep.waitUntilExit()
        let pgrepData = pgrepOut.fileHandleForReading.readDataToEndOfFile()
        let pgrepOutput = String(data: pgrepData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let pid = pgrepOutput.components(separatedBy: .newlines).first.flatMap({ Int32($0) }), pid > 0 {
            return pid
        }

        // Special case: Colima's Docker daemon runs under a different process name
        if FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.colima/default/docker.sock") {
            return 1
        }

        return nil
    }
}
