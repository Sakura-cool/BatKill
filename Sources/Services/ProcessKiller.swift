//  ProcessKiller.swift
//  BatKill
//
//  Terminates applications, launch agents, and background services when the
//  Mac switches to battery, and restores them when AC power returns.
//
//  Termination strategy (by app category):
//  - Applications: NSRunningApplication.terminate() -> .forceTerminate()
//    -> SIGTERM -> SIGKILL -> killall (escalating force)
//  - Launch Agents: launchctl bootout -> killall fallback
//  - Services: direct "<name> stop" -> killall -> detect respawn,
//             patch plist (temporary KeepAlive=crash-only), reload, kill again
//  - Custom processes: SIGTERM -> SIGKILL by PID -> killall fallback
//
//  Restore strategy:
//  - Applications: NSWorkspace.open() (skips if already running)
//  - Launch Agents: launchctl bootstrap
//  - Services: direct start -> brew services start -> launchctl bootstrap

import Cocoa
import Foundation
import UserNotifications

/// Terminates applications, launch agents, and services.
///
/// Manages the lifecycle of "killed on battery" apps through a persisted
/// restore list (`killedRestorePaths` in UserDefaults). When AC power
/// returns, `restoreKilledApps()` re-launches everything that was killed.
///
/// All kill/restore operations run on a background queue with UI state
/// published on the main thread via `@Published` properties.
final class ProcessKiller: ObservableObject {
    /// Whether a kill operation is currently in progress.
    @Published var isKilling = false

    /// Whether a restore operation is currently in progress.
    @Published var isRestoring = false

    /// Results of the most recent kill operation (app name -> success).
    @Published var lastKillResults: [String: Bool] = [:]

    /// Running count of successfully terminated apps (this session).
    @Published var killCount: Int = 0

    /// Running count of successfully restored apps (this session).
    @Published var restoreCount: Int = 0

    /// Number of apps in the persisted restore list (pending AC return).
    /// Includes both killed apps (to relaunch) and suspended apps (to resume).
    @Published var pendingRestoreCount: Int = 0

    // MARK: - Restore Progress & Gating (v0.2.6)

    /// Apps restored so far in the current restore sequence.
    @Published var restoreDone: Int = 0

    /// Total apps in the current restore sequence (0 = idle).
    @Published var restoreTotal: Int = 0

    /// Name of the next app to restore (valid during the wait interval).
    @Published var nextRestoreName: String?

    /// Current restore phase (waiting / restoring / idle) — drives the UI
    /// progress caption and the wait-interval segment.
    @Published var restorePhase: RestorePhase = .idle

    /// Auto-restore gate state (low-battery / contact-issue / in-progress);
    /// only the automatic path is gated, manual entries bypass it.
    @Published var restoreGateState: RestoreGateState = .idle

    /// Why the gate is held, driving the banner copy (design-spec §6.3 / S5).
    @Published var restoreGateReason: RestoreGateReason = .lowBattery

    /// Whether the current restore was started manually (UI entry); when true,
    /// the AppDelegate battery auto-pause logic (AC-615~617) is skipped.
    @Published var manualRestoreOverride: Bool = false

    /// Cancellation flag for the in-flight restore sequence. Checked at the
    /// start of each iteration; when set, remaining apps stay pending (AC-612).
    var restoreCancelled = false

    /// Session token for the restore sequence. Incremented on each start; a
    /// stale sequence's completion skips state application (never clobbers a
    /// newer run's `isRestoring`/`restorePhase`).
    var restoreSession = 0

    /// Seconds to wait for a graceful `terminate()` before escalating to force
    /// (longer than the 0.3s force-chain fallback) so state-saving apps persist.
    private let gracefulWaitSeconds: TimeInterval = 2.0

    // MARK: - Init

    /// Initializes the pending count from the persisted restore lists.
    init() {
        pendingRestoreCount = killedRestorePaths.count + suspendedPaths.count
    }

    // MARK: - Persisted "Killed on Battery" List

    /// Paths of apps that were killed by BatKill and should be restored
    /// when AC power returns. Backed by UserDefaults for crash safety.
    /// Only includes apps that were successfully terminated.
    var killedRestorePaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "killedRestorePaths") ?? [] }
        set {
            DispatchQueue.main.async {
                UserDefaults.standard.set(newValue, forKey: "killedRestorePaths")
                self.pendingRestoreCount = newValue.count + self.suspendedPaths.count
            }
        }
    }

    // MARK: - Persisted "Suspended on Battery" List

    /// Paths of apps that were `SIGSTOP`-frozen by BatKill (suspend mode) and
    /// should be `SIGCONT`-resumed when AC power returns. Backed by UserDefaults
    /// so the frozen set survives a BatKill restart (the processes stay frozen).
    /// These apps are NOT killed -- they remain running (stopped) and keep state.
    ///
    /// The UserDefaults write is synchronous (not main-async) so reads within
    /// the same background operation (e.g. `killSelected` checking
    /// `isSuspendedPath`) see the just-suspended path immediately. Only the
    /// `@Published` count update is dispatched to the main thread.
    var suspendedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "suspendedPaths") ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "suspendedPaths")
            DispatchQueue.main.async {
                self.pendingRestoreCount = self.killedRestorePaths.count + newValue.count
            }
        }
    }

    /// Convenience: whether an app path is currently in the suspended set.
    private func isSuspendedPath(_ path: String) -> Bool {
        suspendedPaths.contains(path)
    }

    /// Adds an app path to the suspended set (after a successful SIGSTOP).
    private func addSuspendedPath(_ path: String) {
        var paths = suspendedPaths
        if !paths.contains(path) {
            paths.append(path)
            suspendedPaths = paths
        }
    }

    /// Removes an app path from the suspended set (after SIGCONT resume or
    /// when the process is no longer resumable).
    private func removeSuspendedPath(_ path: String) {
        var paths = suspendedPaths
        paths.removeAll { $0 == path }
        suspendedPaths = paths
    }

    /// Read-only access to the list of app IDs pending restore (relaunch + resume),
    /// in the pending list's original order (killed first, then suspended).
    var pendingRestoreAppIds: [String] { orderedRestorePaths(killedRestorePaths, suspendedPaths) }

    /// Read-only access to the list of app IDs currently suspended (SIGSTOP-frozen).
    var suspendedAppIds: [String] { suspendedPaths }

    /// Removes a single app from the restore lists. Behavior differs by state:
    /// - **Suspended** (SIGSTOP-frozen): deleting means the user no longer
    ///   wants it auto-resumed, so the frozen process is **terminated outright**
    ///   (`SIGKILL`) to release the stuck state. Leaving it frozen with no
    ///   restore entry would leak memory and leave a dead window on screen.
    /// - **Killed** (graceful/force, already exited): only the record is removed
    ///   (the process is already gone; the app simply won't be relaunched).
    func removePending(_ appId: String, using apps: [AppItem] = []) {
        if suspendedPaths.contains(appId) {
            terminateFrozenApp(appId, using: apps)
        }
        var killed = killedRestorePaths
        killed.removeAll { $0 == appId }
        killedRestorePaths = killed

        var suspended = suspendedPaths
        suspended.removeAll { $0 == appId }
        suspendedPaths = suspended
    }

    /// Terminates a SIGSTOP-frozen app by its ID. `apps` is used to resolve the
    /// PID; if the app is no longer in the list, falls back to matching a
    /// running app by bundle URL path (appId == path).
    private func terminateFrozenApp(_ appId: String, using apps: [AppItem]) {
        if let app = apps.first(where: { $0.id == appId }), let pid = pidFor(app) {
            kill(pid, SIGKILL)
            logger("removePending: SIGKILL 已冻结应用 \(app.name) (pid \(pid))")
            return
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == appId }) {
            running.forceTerminate()
            logger("removePending: forceTerminate 已冻结应用 (path \(appId))")
        }
    }

    /// Restores a single pending app by its ID and posts a notification.
    func restorePendingSingle(_ appId: String, using apps: [AppItem]) {
        if let name = restoreSingleApp(appId, using: apps) {
            removePending(appId, using: apps)
            restoreCount += 1
            postRestoreNotification(names: [name])
        }
    }

    /// Restores only the selected apps in the pending list (UI selective
    /// recovery). Apps that fail to restore stay pending.
    func restoreSelected(_ apps: [AppItem], selectedPaths: Set<String>, completion: (() -> Void)? = nil) {
        // Union of killed (relaunch) + suspended (resume) pending apps, in list order (AC-603/S3).
        let pending = orderedRestorePaths(killedRestorePaths, suspendedPaths)
        let toRestore = pending.filter { selectedPaths.contains($0) }
        guard !toRestore.isEmpty else {
            logger("restoreSelected: no selected apps in pending list")
            DispatchQueue.main.async { completion?() }
            return
        }
        logger("restoreSelected: restoring \(toRestore)")
        // Manual selective entry: ignore auto gate/pause (AC-608/AC-618).
        manualRestoreOverride = true
        isRestoring = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var restoredNames: [String] = []
            var restoredIds: [String] = []

            for appId in toRestore {
                if let name = self.restoreSingleApp(appId, using: apps) {
                    restoredNames.append(name)
                    restoredIds.append(appId)
                }
            }

            DispatchQueue.main.async {
                if !restoredIds.isEmpty {
                    // Clear restored ids from both the relaunch and resume sets.
                    var remainingKilled = self.killedRestorePaths
                    remainingKilled.removeAll { restoredIds.contains($0) }
                    self.killedRestorePaths = remainingKilled
                    var remainingSuspended = self.suspendedPaths
                    remainingSuspended.removeAll { restoredIds.contains($0) }
                    self.suspendedPaths = remainingSuspended
                }
                self.restoreCount += restoredNames.count
                self.manualRestoreOverride = false
                self.isRestoring = false
                if !restoredNames.isEmpty {
                    self.postRestoreNotification(names: restoredNames)
                }
                completion?()
            }
        }
    }

    // MARK: - Kill (Public API)

    /// Terminates selected + running apps, tracking them for auto-restore on
    /// AC. Runs on a background queue; updates results/counts/persisted list.
    func killSelected(_ apps: [AppItem], trackForRestore: Bool = true, context: LogContext? = nil, completion: (() -> Void)? = nil) {
        let ctx = context ?? LogContext(name: "killSelected")
        let selected = apps.filter { $0.isSelected && $0.isRunning }
        guard !selected.isEmpty else {
            ctx.log("没有需要终止的应用")
            DispatchQueue.main.async { completion?() }
            return
        }
        ctx.log("开始终止 \(selected.count) 个应用: \(selected.map(\.name).joined(separator: ", "))")

        // A kill (manual "Stop Selected" or auto battery switch) interrupts any
        // in-flight restore sequence; un-restored apps stay pending (AC-612/613).
        cancelRestore()

        isKilling = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var results: [String: Bool] = [:]

            for app in selected {
                let terminateCtx = ctx.child("terminate")
                terminateCtx.log("终止 \(app.name) (pid: \(app.pid ?? -1))")
                results[app.name] = self.terminate(app)
                terminateCtx.log("结果: \(results[app.name] ?? false ? "成功" : "失败")")
            }

            // Persist killed app IDs so they can be restored when AC returns
            if trackForRestore {
                var restoreList = self.killedRestorePaths
                for (name, success) in results where success {
                    guard let app = selected.first(where: { $0.name == name }) else { continue }
                    let appId = app.id
                    // Suspended apps are tracked in `suspendedPaths` (resumed via
                    // SIGCONT), not in `killedRestorePaths` (relaunched) -- skip here.
                    if !restoreList.contains(appId) && !self.isSuspendedPath(appId) {
                        restoreList.append(appId)
                    }
                }
                self.killedRestorePaths = restoreList
            }

            let successCount = results.values.filter { $0 }.count
            ctx.complete(success: true, extra: "\(successCount)/\(selected.count) 成功")

            DispatchQueue.main.async {
                self.lastKillResults = results
                self.killCount += results.values.filter { $0 }.count
                self.isKilling = false
                self.postKillNotification(apps: selected, results: results)
                completion?()
            }
        }
    }

    // MARK: - Restore (Public API)

    /// Restores ALL apps in the persisted kill list (auto on AC, or manual).
    /// Runs on a background thread; clears the restore list on completion.
    func restoreKilledApps(using apps: [AppItem], context: LogContext? = nil, completion: (() -> Void)? = nil) {
        let ctx = context ?? LogContext(name: "restoreKilledApps")
        // S4: one restore at a time; reject a concurrent start (no overlap).
        guard !isRestoring else {
            logger("restoreKilledApps: 恢复已在进行，忽略重复启动")
            completion?()
            return
        }
        // Union of killed apps (relaunch) and suspended apps (SIGCONT resume);
        // never both in one list, but robust against stale entries. Preserves
        // the pending list's order (AC-603 / S3).
        let paths = orderedRestorePaths(killedRestorePaths, suspendedPaths)
        guard !paths.isEmpty else {
            ctx.log("没有需要恢复的应用")
            DispatchQueue.main.async { completion?() }
            return
        }
        ctx.log("开始批量恢复 \(paths.count) 个应用")

        // Manual batch entry (UI "Bulk Quick Restore"): ignore auto gate/pause
        // (AC-608/AC-618). Progress fields drive the shared RestoreProgressRow.
        manualRestoreOverride = true
        restoreCancelled = false
        let session = restoreSession + 1
        restoreSession = session
        isRestoring = true
        // S3: preserve a held low-battery gate; the completion keeps it intact.
        if restoreGateState != .delayedLowBattery {
            restoreGateState = .restoring
        }
        restoreTotal = paths.count
        restoreDone = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var restoredNames: [String] = []
            var restoredIds: [String] = []

            for (i, appId) in paths.enumerated() {
                // Batch loop has no wait points; honor cancel + stale-run stop (S4).
                if self.restoreCancelled || self.restoreSession != session { break }
                let name = self.displayName(for: appId, using: apps)
                DispatchQueue.main.async {
                    self.restorePhase = .restoring(name: name)
                    self.nextRestoreName = name
                }
                let restoreCtx = ctx.child("restoreSingle")
                if let restoredName = self.restoreSingleApp(appId, using: apps) {
                    restoredNames.append(restoredName)
                    restoredIds.append(appId)
                    restoreCtx.log("恢复 \(restoredName) 成功")
                } else {
                    restoreCtx.log("恢复 \(appId) 失败")
                }
                DispatchQueue.main.async {
                    self.restoreDone = i + 1
                }
            }

            ctx.complete(success: true, extra: "\(restoredNames.count)/\(paths.count) 成功")

            DispatchQueue.main.async {
                if !restoredIds.isEmpty {
                    // Clear restored ids from both the relaunch and resume sets.
                    var remainingKilled = self.killedRestorePaths
                    remainingKilled.removeAll { restoredIds.contains($0) }
                    self.killedRestorePaths = remainingKilled
                    var remainingSuspended = self.suspendedPaths
                    remainingSuspended.removeAll { restoredIds.contains($0) }
                    self.suspendedPaths = remainingSuspended
                }
                // A stale sequence (superseded by a newer start) must not clobber
                // the newer run's state; its list cleanup above is still applied.
                guard self.restoreSession == session else {
                    completion?()
                    return
                }
                self.restoreCount += restoredNames.count
                let wasCancelled = self.restoreCancelled
                self.restoreCancelled = false
                self.manualRestoreOverride = false
                self.isRestoring = false
                self.restorePhase = .idle
                self.nextRestoreName = nil
                // Preserve an externally-set low-battery gate (AC-617).
                if self.restoreGateState != .delayedLowBattery { self.restoreGateState = (wasCancelled || restoredIds.isEmpty) ? .idle : .completed }
                self.restoreTotal = 0
                self.restoreDone = 0
                if !restoredNames.isEmpty && !wasCancelled {
                    self.postRestoreNotification(mode: .batch, count: restoredNames.count)
                }
                completion?()
            }
        }
    }

    // MARK: - Single App Restore

    /// Restores a single app by ID; returns the display name on success (or
    /// if already running), `nil` otherwise. Strategy varies by category:
    /// `.application` open / `.launchAgent` bootstrap / `.service` start.
    func restoreSingleApp(_ appId: String, using apps: [AppItem]) -> String? {
        // Suspend mode: `SIGCONT` resume the frozen process in place, preserving
        // its exact state. If the process is gone (rebooted / manually quit),
        // remove it from the suspended set and fall back to a fresh relaunch.
        if isSuspendedPath(appId) {
            if let pid = currentPid(for: appId, using: apps), kill(pid, SIGCONT) == 0 {
                removeSuspendedPath(appId)
                logger("restoreSingleApp: SIGCONT resumed \(appId) (pid \(pid))")
                // Restore the window that was hidden before suspension.
                if let app = apps.first(where: { $0.id == appId }) {
                    unhideApp(app)
                }
                return displayName(for: appId, using: apps)
            }
            logger("restoreSingleApp: suspended \(appId) not resumable, relaunching")
            removeSuspendedPath(appId)
            // Fall through to the relaunch path below
        }

        if appId.hasSuffix(".app") {
            let url = URL(fileURLWithPath: appId)
            let alreadyRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL?.path == appId
            }
            if !alreadyRunning {
                NSWorkspace.shared.open(url)
            }
            // Return display name from the app list, or fall back to file name
            if let app = apps.first(where: { $0.id == appId }) {
                return app.name
            }
            return (appId as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        } else if let app = apps.first(where: { $0.id == appId }), app.category == .launchAgent {
            let proc = Process()
            proc.launchPath = "/bin/launchctl"
            proc.arguments = ["bootstrap", "gui/\(getuid())", app.path]
            try? proc.run()
            proc.waitUntilExit()
            return app.name
        } else if let app = apps.first(where: { $0.id == appId }), app.category == .service {
            // Restore original KeepAlive if BatKill patched it during kill
            if let label = app.serviceLabel {
                let restored = restoreKeepAlive(label: label)
                if restored {
                    logger("restoreSingleApp: restored original KeepAlive for \(label)")
                }
            }

            // Strategy 1: 直接以服务可执行文件启动（v0.1.6 FIX-001：不经 shell，参数数组传递）
            if let executable = ProcessRunner.resolveExecutable(named: app.processName) {
                if let result = try? ProcessRunner.run(executable: executable, arguments: ["start"]),
                   result.succeeded {
                    return app.name
                }
            } else {
                logger("restoreSingleApp: 未找到可执行文件 \(app.processName)，跳过直接启动策略")
            }

            // Strategy 2: brew services start（homebrew 托管服务；直调 brew 二进制 + 白名单校验）
            if app.serviceLabel?.hasPrefix("homebrew.mxcl.") == true {
                if let brew = ProcessRunner.brewPath(),
                   ProcessRunner.isValidExternalIdentifier(app.processName),
                   let result = try? ProcessRunner.run(executable: brew,
                                                       arguments: ["services", "start", app.processName],
                                                       environment: ProcessRunner.defaultSearchEnvironment),
                   result.succeeded {
                    return app.name
                }
                logger("restoreSingleApp: brew services start 未成功或服务名未通过白名单：\(app.processName)")
            }

            // Strategy 3: Try launchctl bootstrap with the service plist
            if let label = app.serviceLabel {
                let plistPath = findPlistPath(for: label)
                if let plistPath = plistPath {
                    let proc = Process()
                    proc.launchPath = "/bin/launchctl"
                    proc.arguments = ["bootstrap", "gui/\(getuid())", plistPath]
                    proc.standardOutput = Pipe()
                    proc.standardError = Pipe()
                    try? proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 { return app.name }
                }
            }

            return nil
        }

        return nil
    }

    // MARK: - Termination Strategies

    /// Routes termination to the appropriate strategy based on the app's
    /// category (application, launch agent, service, or custom process).
    private func terminate(_ app: AppItem) -> Bool {
        switch app.category {
        case .application:  return terminateApplication(app)
        case .launchAgent:  return unloadLaunchAgent(app)
        case .service:      return stopService(app)
        case .custom:       return terminateCustom(app)
        }
    }

    /// Terminates a custom (or system XPC/helper) process. In `.suspend`
    /// mode it is `SIGSTOP`-frozen so it can be `SIGCONT`-resumed in place on
    /// AC (the only way to restore a process that has no launch mechanism).
    /// Otherwise it uses the existing PID kill chain.
    private func terminateCustom(_ app: AppItem) -> Bool {
        if app.suspendStrategy == .suspend {
            return suspendApp(app)
        }
        return killProcessByPid(app)
    }

    /// Terminates a GUI application according to its per-app suspend strategy.
    /// `.suspend`/`.graceful` fall back to the force chain on failure so a
    /// batch never stalls on an app that can't be preserved.
    private func terminateApplication(_ app: AppItem) -> Bool {
        switch app.suspendStrategy {
        case .suspend:  return suspendApp(app)
        case .graceful: return terminateGracefully(app)
        case .force:    return killApplication(app)
        }
    }

    /// Freezes a GUI application via `SIGSTOP` (suspend mode), preserving its
    /// exact state in memory. On success the path is tracked in `suspendedPaths`
    /// for AC-time `SIGCONT` resume. Falls back to graceful, then force.
    ///
    /// Before freezing, the app's windows are hidden (`NSRunningApplication.hide`)
    /// so a frozen (SIGSTOP) app does not leave a dead window covering the screen.
    /// Hiding is best-effort and non-fatal: if it fails, suspension still proceeds.
    private func suspendApp(_ app: AppItem) -> Bool {
        guard let pid = pidFor(app) else {
            logger("suspendApp: no PID for \(app.name), falling back to graceful")
            return terminateGracefully(app)
        }
        let hid = hideApp(app)
        if kill(pid, SIGSTOP) == 0 {
            addSuspendedPath(app.path)
            logger("suspendApp: SIGSTOP pid=\(pid) \(app.name)\(hid ? " (window hidden)" : "")")
            return true
        }
        logger("suspendApp: SIGSTOP failed for \(app.name), falling back to graceful")
        return terminateGracefully(app)
    }

    /// Hides a GUI application's windows before it is suspended, so a frozen
    /// (SIGSTOP) app does not leave a dead window covering the screen.
    /// Uses AppleScript `set visible` (System Events) as the primary mechanism
    /// -- verified reliable for normal GUI apps -- with `NSRunningApplication.hide()`
    /// as a fallback. Best-effort: returns success; failure is non-fatal
    /// (suspension still proceeds).
    private func hideApp(_ app: AppItem) -> Bool {
        guard app.category == .application else { return false }
        if setAppVisible(app, visible: false) {
            // The AppleScript returns once the hide event is handled, but the
            // window-hide animation may still be playing. Wait for it to finish
            // before SIGSTOP, so the frozen app's window is fully off-screen.
            Thread.sleep(forTimeInterval: 0.8)
            return true
        }
        // Fallback: NSRunningApplication.hide() (reliable in a GUI app context).
        if let running = runningApp(for: app), running.hide() {
            return true
        }
        logger("hideApp: failed to hide \(app.name), proceeding without hiding")
        return false
    }

    /// Unhides a GUI application after it is resumed (SIGCONT), restoring the
    /// windows that were hidden before suspension. Idempotent -- no-op if the
    /// app was not hidden or is not a `.application`.
    private func unhideApp(_ app: AppItem) {
        guard app.category == .application else { return }
        if setAppVisible(app, visible: true) {
            return
        }
        if let running = runningApp(for: app), running.isHidden {
            running.unhide()
        }
    }

    /// Sets an app's visibility via AppleScript `System Events`, matched by the
    /// app's **executable name** (`processName`, i.e. `CFBundleExecutable`).
    /// System Events' `name` attribute is the process/executable name, which is
    /// NOT the display name (`app.name`) -- apps like WeCom show "wecom" in the
    /// list but their process name is "企业微信", so matching by display name
    /// fails (-1719) and the window stays visible over a frozen process.
    /// Returns whether the script reported success.
    private func setAppVisible(_ app: AppItem, visible: Bool) -> Bool {
        runAppleScript(appVisibilityScript(appName: appVisibilityMatchName(app), visible: visible))
    }

    /// Runs an AppleScript via `osascript`, returning whether it succeeded.
    /// Bounded by a timeout so a hung `osascript` (e.g. unresponsive System
    /// Events) cannot stall the suspend/restore flow indefinitely.
    private func runAppleScript(_ script: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            let deadline = Date().addingTimeInterval(5.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if proc.isRunning {
                proc.terminate()
                logger("runAppleScript: osascript timed out after 5s")
                return false
            }
            return proc.terminationStatus == 0
        } catch {
            logger("runAppleScript: failed to launch osascript: \(error)")
            return false
        }
    }

    /// Resolves the `NSRunningApplication` for an app, preferring the cached
    /// PID, then bundle identifier.
    private func runningApp(for app: AppItem) -> NSRunningApplication? {
        if let pid = app.pid, let running = NSRunningApplication(processIdentifier: pid) {
            return running
        }
        if let bid = app.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        }
        return nil
    }

    /// Gracefully quits a GUI application with an extended wait so the app can
    /// persist its own state (autosave / resume), then escalates to force.
    /// The extended wait (`gracefulWaitSeconds`, 2.0s vs 0.3s in
    /// `killApplication`) gives state-saving apps time to write documents
    /// before the process exits.
    private func terminateGracefully(_ app: AppItem) -> Bool {
        if let bid = app.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            running.forEach { $0.terminate() }
            Thread.sleep(forTimeInterval: gracefulWaitSeconds)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }

            // Escalate: force terminate, then direct signals, then killall
            running.forEach { $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
        }

        if let pid = app.pid {
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.2)
            if !isAlive(pid) { return true }
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.2)
            if !isAlive(pid) { return true }
        }

        return killall(app.processName)
    }

    /// Resolves the PID for an app, preferring the cached `app.pid`, then
    /// `NSRunningApplication` by bundle identifier.
    private func pidFor(_ app: AppItem) -> Int32? {
        if let pid = app.pid { return pid }
        if let bid = app.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            return running.processIdentifier
        }
        return nil
    }

    /// Resolves the current PID for an app path, preferring the freshly
    /// refreshed app list, then `NSRunningApplication` by bundle URL.
    private func currentPid(for appId: String, using apps: [AppItem]) -> Int32? {
        if let app = apps.first(where: { $0.id == appId }), let pid = app.pid {
            return pid
        }
        for running in NSWorkspace.shared.runningApplications {
            if running.bundleURL?.path == appId {
                return running.processIdentifier
            }
        }
        return nil
    }

    /// Resolves a display name for an app id from the app list, or falls back
    /// to the `.app` bundle name.
    func displayName(for appId: String, using apps: [AppItem]) -> String {
        if let app = apps.first(where: { $0.id == appId }) {
            return app.name
        }
        return (appId as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    }

    /// Force-kills a GUI application using escalating strategies:
    ///
    /// 1. `NSRunningApplication.terminate()` (graceful, with 0.3s wait)
    /// 2. `NSRunningApplication.forceTerminate()` (SIGKILL, with 0.3s wait)
    /// 3. `SIGTERM` -> `SIGKILL` via `kill()` PID (0.2s between each)
    /// 4. `killall` by process name (last resort)
    ///
    /// No AppleScript is used to avoid triggering confirmation dialogs.
    private func killApplication(_ app: AppItem) -> Bool {
        // Strategy 1: NSRunningApplication (graceful, then forced)
        if let bid = app.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            running.forEach { $0.terminate() }
            Thread.sleep(forTimeInterval: 0.3)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
            running.forEach { $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
        }

        // Strategy 2: Direct signal delivery by PID
        if let pid = app.pid {
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.2)
            if !isAlive(pid) { return true }
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.2)
            return !isAlive(pid)
        }

        // Strategy 3: killall by process name (last resort)
        return killall(app.processName)
    }

    /// Unloads a user launch agent via `launchctl bootout`.
    /// Falls back to `killProcessByName()` if the launchctl command fails.
    private func unloadLaunchAgent(_ app: AppItem) -> Bool {
        let proc = Process()
        proc.launchPath = "/bin/launchctl"
        proc.arguments = ["bootout", "gui/\(getuid())/\(app.processName)"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return killProcessByName(app.processName) }
        proc.waitUntilExit()
        if proc.terminationStatus == 0 { return true }
        return killProcessByName(app.processName)
    }

    /// Kills a background process by its stored PID using SIGTERM/SIGKILL.
    /// Falls back to `killProcessByName()` if no PID is available.
    private func killProcessByPid(_ app: AppItem) -> Bool {
        guard let pid = app.pid else { return killProcessByName(app.processName) }
        kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.3)
        if !isAlive(pid) { return true }
        kill(pid, SIGKILL); Thread.sleep(forTimeInterval: 0.2)
        return !isAlive(pid)
    }

    /// Kills all processes matching the given name using `/usr/bin/killall`.
    /// Best-effort: returns `true` if the command ran, regardless of result.
    @discardableResult
    private func killProcessByName(_ name: String) -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/bin/killall"
        proc.arguments = [name]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Convenience wrapper around `killProcessByName()`.
    private func killall(_ name: String) -> Bool {
        killProcessByName(name)
    }

    /// Stops a background service using a two-pass strategy that preserves
    /// the user's launchd plist for next-login auto-start.
    ///
    /// Pass 1 — Try to stop the process cleanly:
    ///   1. Direct `<processName> stop`
    ///   2. `killall` by process name
    ///
    /// Pass 2 — If launchd respawned it (KeepAlive=true):
    ///   1. Save the original KeepAlive value to UserDefaults
    ///   2. Temporarily set plist to `KeepAlive = { SuccessfulExit = false }`
    ///      (crash restarts → restart on non-zero exit only)
    ///   3. `launchctl bootout` then `bootstrap` to reload patched plist
    ///   4. Kill again — clean exit (exit 0) → launchd won't restart
    ///
    /// On restore, the original KeepAlive is written back so the plist
    /// is fully restored to the user's original configuration.
    ///
    /// Works correctly for ALL plist configurations:
    ///   - No KeepAlive:             Pass 1 stops it, process stays dead ✓
    ///   - KeepAlive SuccessfulExit=false: Pass 1 exit 0, no restart ✓
    ///   - KeepAlive=true:           Pass 1 respawns → Pass 2 patches &
    ///                               re-registers → clean exit sticks ✓
    private func stopService(_ app: AppItem) -> Bool {
        // ── Pass 1: Try to stop the process ──
        // v0.1.6 FIX-001：改直调服务可执行文件（不经 shell 命令文本）
        if let executable = ProcessRunner.resolveExecutable(named: app.processName) {
            _ = try? ProcessRunner.run(executable: executable, arguments: ["stop"])
        } else {
            logger("stopService: 未找到可执行文件 \(app.processName)，跳过直接停止策略")
        }
        killProcessByName(app.processName)

        // ── Pass 2: Check if launchd respawned it ──
        Thread.sleep(forTimeInterval: 1.5)
        if runningProcessExists(app.processName), let label = app.serviceLabel {
            logger("stopService: launchd respawned \(app.processName), patching plist")
            patchPlistForKillOnce(label: label, serviceName: app.processName)
        }

        return !runningProcessExists(app.processName)
    }

    /// Temporarily patches a service's launchd plist so that `KeepAlive`
    /// only restarts on crash (non-zero exit), not on manual stop.
    ///
    /// Saves the original KeepAlive value to UserDefaults so
    /// `restoreSingleApp()` can restore it on AC return.
    private func patchPlistForKillOnce(label: String, serviceName: String) {
        guard let plistPath = findPlistPath(for: label),
              let dict = NSMutableDictionary(contentsOfFile: plistPath)
        else { return }

        // Save a backup of the original plist file before modifying
        let backupUUID = UUID().uuidString
        let backupPath = NSTemporaryDirectory() + "batkill_plist_backup_\(backupUUID).plist"
        try? FileManager.default.copyItem(atPath: plistPath, toPath: backupPath)
        UserDefaults.standard.set(backupPath, forKey: "batkill_plistBackup_\(label)")

        // Save original KeepAlive to UserDefaults
        let keepAliveKey = "batkill_originalKeepAlive_\(label)"
        if let originalKeepAlive = dict["KeepAlive"] {
            if let data = try? JSONSerialization.data(withJSONObject: originalKeepAlive, options: .fragmentsAllowed),
               let json = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: keepAliveKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: keepAliveKey)
        }

        // Set KeepAlive to crash-only: restart on non-zero exit only
        dict["KeepAlive"] = ["SuccessfulExit": false]

        guard dict.write(toFile: plistPath, atomically: true) else {
            logger("patchPlistForKillOnce: failed to write plist")
            return
        }

        // Reload the plist: bootout old service, bootstrap patched one
        launchctlManage(action: "bootout", label: label)
        Thread.sleep(forTimeInterval: 0.3)
        let loaded = launchctlManage(action: "bootstrap", label: label, plistPath: plistPath)

        // Kill — clean exit (exit 0) → launchd won't restart (SuccessfulExit=false)
        Thread.sleep(forTimeInterval: 0.5)
        killProcessByName(serviceName)
        if loaded {
            Thread.sleep(forTimeInterval: 0.5)
            killProcessByName(serviceName)
        }
    }

    /// Restores the original KeepAlive value saved by `patchPlistForKillOnce`
    /// back into the plist and reloads it via launchctl.
    /// Returns `true` on success, `false` if nothing to restore.
    private func restoreKeepAlive(label: String) -> Bool {
        let keepAliveKey = "batkill_originalKeepAlive_\(label)"
        guard let json = UserDefaults.standard.string(forKey: keepAliveKey),
              let data = json.data(using: .utf8),
              let originalKeepAlive = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
              let plistPath = findPlistPath(for: label),
              let dict = NSMutableDictionary(contentsOfFile: plistPath)
        else { return false }

        // Write back the original KeepAlive value
        if let keepAliveDict = originalKeepAlive as? [String: Any] {
            dict["KeepAlive"] = keepAliveDict
        } else if originalKeepAlive is Bool || originalKeepAlive is NSNumber {
            // Original was a plain boolean — write it back directly
            dict["KeepAlive"] = originalKeepAlive
        } else {
            // Original was absent or an unsupported type — remove the key
            dict.removeObject(forKey: "KeepAlive")
        }

        guard dict.write(toFile: plistPath, atomically: true) else {
            logger("restoreKeepAlive: failed to write plist for \(label)")
            return false
        }

        UserDefaults.standard.removeObject(forKey: keepAliveKey)

        // Remove the backup plist file created by patchPlistForKillOnce
        let backupKey = "batkill_plistBackup_\(label)"
        if let backupPath = UserDefaults.standard.string(forKey: backupKey) {
            try? FileManager.default.removeItem(atPath: backupPath)
            UserDefaults.standard.removeObject(forKey: backupKey)
        }

        return true
    }

    /// Runs `launchctl <action> gui/<uid>/<label>` or `launchctl bootstrap gui/<uid> <plistPath>`.
    /// Returns `true` if the command succeeded.
    @discardableResult
    private func launchctlManage(action: String, label: String, plistPath: String? = nil) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        if action == "bootstrap", let plistPath = plistPath {
            proc.arguments = ["bootstrap", "gui/\(getuid())", plistPath]
        } else {
            proc.arguments = [action, "gui/\(getuid())/\(label)"]
        }
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Checks whether at least one process with the given name is alive.
    private func runningProcessExists(_ name: String) -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/bin/pgrep"
        proc.arguments = ["-x", name]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    /// Searches ~/Library/LaunchAgents/ for a plist file whose "Label"
    /// key matches the given launchd label. Returns the full path if found.
    private func findPlistPath(for label: String) -> String? {
        let userAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        let fm = FileManager.default

        if let contents = try? fm.contentsOfDirectory(atPath: userAgentsDir) {
            for item in contents where item.hasSuffix(".plist") {
                let fullPath = "\(userAgentsDir)/\(item)"
                if let dict = NSDictionary(contentsOfFile: fullPath),
                   let loadedLabel = dict["Label"] as? String,
                   loadedLabel == label {
                    return fullPath
                }
            }
        }

        return nil
    }

    // MARK: - Utilities

    /// Checks whether a process with the given PID is still alive
    /// by sending signal 0 (no signal, just permission check).
    private func isAlive(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0
    }

    /// Escapes special characters in a string for safe embedding in AppleScript.
    private func escapeAppleScript(_ str: String) -> String {
        escapeAppleScriptText(str)
    }
}
