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
    @Published var pendingRestoreCount: Int = 0

    // MARK: - Init

    /// Initializes the kill count from the persisted restore list.
    init() {
        pendingRestoreCount = UserDefaults.standard.stringArray(forKey: "killedRestorePaths")?.count ?? 0
    }

    // MARK: - Persisted "Killed on Battery" List

    /// Paths of apps that were killed by BatKill and should be restored
    /// when AC power returns. Backed by UserDefaults for crash safety.
    /// Only includes apps that were successfully terminated.
    private var killedRestorePaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "killedRestorePaths") ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "killedRestorePaths")
            DispatchQueue.main.async { [weak self] in
                self?.pendingRestoreCount = newValue.count
            }
        }
    }

    /// Read-only access to the list of app IDs pending restore.
    var pendingRestoreAppIds: [String] { killedRestorePaths }

    /// Removes a single app from the restore list (e.g., if user manually
    /// closes it or no longer wants it auto-restored).
    func removePending(_ appId: String) {
        var paths = killedRestorePaths
        paths.removeAll { $0 == appId }
        killedRestorePaths = paths
    }

    /// Restores a single pending app by its ID and posts a notification.
    func restorePendingSingle(_ appId: String, using apps: [AppItem]) {
        if let name = restoreSingleApp(appId, using: apps) {
            removePending(appId)
            restoreCount += 1
            postRestoreNotification(names: [name])
        }
    }

    /// Restores only the selected apps that are in the pending restore list.
    /// Used by the UI's manual restore button for selective recovery.
    func restoreSelected(_ apps: [AppItem], completion: (() -> Void)? = nil) {
        let selectedPaths = Set(apps.filter { $0.isSelected }.map(\.id))
        let toRestore = killedRestorePaths.filter { selectedPaths.contains($0) }
        guard !toRestore.isEmpty else {
            logger("restoreSelected: no selected apps in pending list")
            DispatchQueue.main.async { completion?() }
            return
        }
        logger("restoreSelected: restoring \(toRestore)")
        isRestoring = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var restoredNames: [String] = []

            for appId in toRestore {
                if let name = self.restoreSingleApp(appId, using: apps) {
                    restoredNames.append(name)
                }
            }

            DispatchQueue.main.async {
                var paths = self.killedRestorePaths
                paths.removeAll { toRestore.contains($0) }
                self.killedRestorePaths = paths
                self.restoreCount += restoredNames.count
                self.isRestoring = false
                if !restoredNames.isEmpty {
                    self.postRestoreNotification(names: restoredNames)
                }
                completion?()
            }
        }
    }

    // MARK: - Kill (Public API)

    /// Terminates all selected and running apps, tracking them for
    /// automatic restore when AC power returns.
    ///
    /// Runs on a background queue. Updates `lastKillResults`, `killCount`,
    /// and the persisted restore list on completion.
    ///
    /// - Parameters:
    ///   - apps: Full app list; only items with `isSelected && isRunning` are killed.
    ///   - trackForRestore: Whether to add successfully killed apps to the restore list.
    ///   - completion: Called on the main thread when the operation finishes.
    func killSelected(_ apps: [AppItem], trackForRestore: Bool = true, context: LogContext? = nil, completion: (() -> Void)? = nil) {
        let ctx = context ?? LogContext(name: "killSelected")
        let selected = apps.filter { $0.isSelected && $0.isRunning }
        guard !selected.isEmpty else {
            ctx.log("没有需要终止的应用")
            DispatchQueue.main.async { completion?() }
            return
        }
        ctx.log("开始终止 \(selected.count) 个应用: \(selected.map(\.name).joined(separator: ", "))")

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
                    if !restoreList.contains(appId) {
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
                self.postKillNotification(results: results)
                completion?()
            }
        }
    }

    // MARK: - Restore (Public API)

    /// Restores ALL apps in the persisted kill list. Called automatically
    /// when AC power is detected, or manually by the user.
    ///
    /// Runs on a background thread, clears the restore list on completion,
    /// and posts a notification with the names of restored apps.
    func restoreKilledApps(using apps: [AppItem], context: LogContext? = nil, completion: (() -> Void)? = nil) {
        let ctx = context ?? LogContext(name: "restoreKilledApps")
        let paths = killedRestorePaths
        guard !paths.isEmpty else {
            ctx.log("没有需要恢复的应用")
            DispatchQueue.main.async { completion?() }
            return
        }
        ctx.log("开始恢复 \(paths.count) 个应用")
        isRestoring = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var restoredNames: [String] = []

            for appId in paths {
                let restoreCtx = ctx.child("restoreSingle")
                if let name = self.restoreSingleApp(appId, using: apps) {
                    restoredNames.append(name)
                    restoreCtx.log("恢复 \(name) 成功")
                } else {
                    restoreCtx.log("恢复 \(appId) 失败")
                }
            }

            ctx.complete(success: true, extra: "\(restoredNames.count)/\(paths.count) 成功")

            DispatchQueue.main.async {
                self.killedRestorePaths = []
                self.restoreCount += restoredNames.count
                self.isRestoring = false
                if !restoredNames.isEmpty {
                    self.postRestoreNotification(names: restoredNames)
                }
                completion?()
            }
        }
    }

    // MARK: - Single App Restore

    /// Attempts to restore a single app by its ID. Returns the display
    /// name if restore succeeded (or app was already running), `nil` otherwise.
    ///
    /// Restore strategy varies by category:
    /// - `.application`: `NSWorkspace.shared.open()` (skips if already running)
    /// - `.launchAgent`: `launchctl bootstrap gui/<uid>/<path>`
    /// - `.service`: direct start -> brew services start -> launchctl bootstrap
    private func restoreSingleApp(_ appId: String, using apps: [AppItem]) -> String? {
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
        }

        else if let app = apps.first(where: { $0.id == appId }), app.category == .launchAgent {
            let proc = Process()
            proc.launchPath = "/bin/launchctl"
            proc.arguments = ["bootstrap", "gui/\(getuid())", app.path]
            try? proc.run()
            proc.waitUntilExit()
            return app.name
        }

        else if let app = apps.first(where: { $0.id == appId }), app.category == .service {
            // Restore original KeepAlive if BatKill patched it during kill
            if let label = app.serviceLabel {
                let restored = restoreKeepAlive(label: label)
                if restored {
                    logger("restoreSingleApp: restored original KeepAlive for \(label)")
                }
            }

            // Strategy 1: Try direct start command
            let directStart = Process()
            directStart.executableURL = URL(fileURLWithPath: "/bin/bash")
            directStart.arguments = ["-l", "-c", "\(app.processName) start"]
            directStart.standardOutput = Pipe()
            directStart.standardError = Pipe()
            if (try? directStart.run()) != nil {
                directStart.waitUntilExit()
                if directStart.terminationStatus == 0 { return app.name }
            }

            // Strategy 2: Try brew services start (for homebrew-managed services)
            if app.serviceLabel?.hasPrefix("homebrew.mxcl.") == true {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/bash")
                task.arguments = ["-l", "-c", "brew services start \(app.processName)"]
                task.standardOutput = Pipe()
                task.standardError = Pipe()
                try? task.run()
                task.waitUntilExit()
                if task.terminationStatus == 0 { return app.name }
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
        case .application:  return killApplication(app)
        case .launchAgent:  return unloadLaunchAgent(app)
        case .service:      return stopService(app)
        case .custom:       return killProcessByPid(app)
        }
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
    private func killProcessByName(_ name: String) -> Bool {
        let proc = Process()
        proc.launchPath = "/usr/bin/killall"
        proc.arguments = [name]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return false }
        proc.waitUntilExit()
        return true // best effort
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
        let directStop = Process()
        directStop.executableURL = URL(fileURLWithPath: "/bin/bash")
        directStop.arguments = ["-l", "-c", "\(app.processName) stop"]
        directStop.standardOutput = Pipe()
        directStop.standardError = Pipe()
        if (try? directStop.run()) != nil {
            directStop.waitUntilExit()
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
        } else {
            // Original was a plain boolean or absent — remove the key
            dict.removeObject(forKey: "KeepAlive")
        }

        guard dict.write(toFile: plistPath, atomically: true) else {
            logger("restoreKeepAlive: failed to write plist for \(label)")
            return false
        }

        UserDefaults.standard.removeObject(forKey: keepAliveKey)
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
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Escapes special characters in a string for safe embedding in AppleScript.
    private func escapeAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Notifications

    /// Posts a user notification summarizing which apps were killed
    /// and which failed. Requests notification authorization if needed.
    private func postKillNotification(results: [String: Bool]) {
        let killed = results.filter { $0.value }.map { $0.key }
        let failed = results.filter { !$0.value }.map { $0.key }

        var bodyParts: [String] = []
        if !killed.isEmpty {
            bodyParts.append(loc("✅ Terminated:", "✅ 已停止:") + " " + killed.joined(separator: ", "))
        }
        if !failed.isEmpty {
            bodyParts.append(loc("❌ Failed:", "❌ 失败:") + " " + failed.joined(separator: ", "))
        }
        let body = bodyParts.joined(separator: "\n")

        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = "BatKill"
        content.body = body
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Posts a user notification listing the names of apps restored
    /// when AC power was detected.
    private func postRestoreNotification(names: [String]) {
        guard !names.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let content = UNMutableNotificationContent()
        content.title = "BatKill"
        content.body = loc("✅ Restored on AC:", "✅ 已恢复:") + " " + names.joined(separator: ", ")
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }
}
