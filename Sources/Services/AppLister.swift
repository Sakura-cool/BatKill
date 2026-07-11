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

    // MARK: - Persisted Selection

    /// Set of app paths that the user has checked in the settings UI.
    /// Persisted to UserDefaults so selections survive app restarts.
    private var selectedPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: selectedPathsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: selectedPathsKey) }
    }

    // MARK: - Public API

    /// Triggers a full background scan of all app categories.
    /// Updates `apps` on the main thread when complete.
    func refreshAppList() {
        isLoading = true
        hasLoaded = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let saved = self.selectedPaths
            let newApps = self.buildAppList(savedPaths: saved)

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
        if apps[idx].isSelected { paths.insert(path) }
        else { paths.remove(path) }
        selectedPaths = paths
    }

    // MARK: - App Discovery (5-Phase Process)

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
            ("/System/Applications", true),
        ]

        for (dir, isSystem) in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = "\(dir)/\(item)"
                guard seen.insert(fullPath).inserted else { continue }

                let bundle = Bundle(path: fullPath)
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
            let fullPath = "/usr/local/opt/\(svc.name)"
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
            let fullPath = "/opt/homebrew/opt/\(svc.name)"
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

        // ── Sort: running apps first, then alphabetically ──
        result.sort { a, b in
            if a.isRunning != b.isRunning { return a.isRunning && !b.isRunning }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return result
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

    /// Executes a shell command via `/bin/bash -l -c` and returns stdout.
    private func shellExec(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-l", "-c", command]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return "" }
        task.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Returns all brew services (running or stopped) via `brew services list`.
    /// For each service, also queries its PID via launchctl and pgrep.
    private func brewAllServices() -> [(name: String, label: String, isRunning: Bool, pid: Int32?)] {
        let output = shellExec("brew services list")
        var services: [(String, String, Bool, Int32?)] = []

        for line in output.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }

            let name = String(parts[0])
            guard !name.isEmpty else { continue }

            let label = "homebrew.mxcl.\(name)"
            let pid = self.brewServicePID(name)
            let isRunning = pid != nil && pid! > 0
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

        for line in output.components(separatedBy: .newlines).dropFirst() {
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
