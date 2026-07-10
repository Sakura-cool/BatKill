import Cocoa
import Foundation
import UserNotifications

/// Terminates applications, launch agents, and services.
final class ProcessKiller: ObservableObject {
    @Published var isKilling = false
    @Published var isRestoring = false
    @Published var lastKillResults: [String: Bool] = [:]
    @Published var killCount: Int = 0
    @Published var restoreCount: Int = 0
    @Published var pendingRestoreCount: Int = 0

    // ──────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────
    init() {
        pendingRestoreCount = UserDefaults.standard.stringArray(forKey: "killedRestorePaths")?.count ?? 0
    }

    // ──────────────────────────────────────────────
    // MARK: - Persisted "Killed on Battery" list
    // ──────────────────────────────────────────────
    /// AppItem.id (path) entries that were killed by BatKill and should be restored on AC.
    private var killedRestorePaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "killedRestorePaths") ?? [] }
        set {
            UserDefaults.standard.set(newValue, forKey: "killedRestorePaths")
            DispatchQueue.main.async { [weak self] in
                self?.pendingRestoreCount = newValue.count
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Kill (Public API)
    // ──────────────────────────────────────────────
    func killSelected(_ apps: [AppItem], trackForRestore: Bool = true, completion: (() -> Void)? = nil) {
        let selected = apps.filter { $0.isSelected && $0.isRunning }
        guard !selected.isEmpty else {
            logger("killSelected: no selected+running apps, skipped")
            DispatchQueue.main.async { completion?() }
            return
        }
        logger("killSelected: killing \(selected.map(\.name))")

        isKilling = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var results: [String: Bool] = [:]

            for app in selected {
                results[app.name] = self.terminate(app)
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

            DispatchQueue.main.async {
                self.lastKillResults = results
                self.killCount += results.values.filter { $0 }.count
                self.isKilling = false
                self.postKillNotification(results: results)
                completion?()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Restore (Public API)
    // ──────────────────────────────────────────────
    func restoreKilledApps(using apps: [AppItem], completion: (() -> Void)? = nil) {
        let paths = killedRestorePaths
        guard !paths.isEmpty else {
            logger("restoreKilledApps: no paths to restore, skipped")
            DispatchQueue.main.async { completion?() }
            return
        }
        logger("restoreKilledApps: restoring \(paths)")
        isRestoring = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var restoredNames: [String] = []

            for appId in paths {
                if let name = self.restoreSingleApp(appId, using: apps) {
                    restoredNames.append(name)
                }
            }

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

    /// Returns the app name if restore succeeded or app was already running.
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

        else if appId.hasPrefix("launchagent:"), let app = apps.first(where: { $0.id == appId }) {
            let proc = Process()
            proc.launchPath = "/bin/launchctl"
            proc.arguments = ["bootstrap", "gui/\(getuid())", app.path]
            try? proc.run()
            proc.waitUntilExit()
            return app.name
        }

        else if appId.hasPrefix("brew:") {
            let name = String(appId.dropFirst("brew:".count))
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-l", "-c", "brew services start \(name)"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return apps.first(where: { $0.id == appId })?.name ?? name
            }
            return nil
        }

        // services: skip — they are managed by launchd / brew
        return nil
    }

    // ──────────────────────────────────────────────
    // MARK: - Termination Strategies
    // ──────────────────────────────────────────────
    private func terminate(_ app: AppItem) -> Bool {
        switch app.category {
        case .application:  return killApplication(app)
        case .launchAgent:  return unloadLaunchAgent(app)
        case .service:      return app.id.hasPrefix("brew:") ? stopBrewService(app) : killProcessByPid(app)
        case .custom:       return killProcessByPid(app)
        }
    }

    /// Force‑kill a GUI application — no AppleScript (skips confirmation dialogs).
    private func killApplication(_ app: AppItem) -> Bool {
        // 1. NSRunningApplication
        if let bid = app.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            running.forEach { $0.terminate() }
            Thread.sleep(forTimeInterval: 0.3)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
            running.forEach { $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
        }

        // 2. SIGTERM + SIGKILL
        if let pid = app.pid {
            kill(pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.2)
            if !isAlive(pid) { return true }
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.2)
            return !isAlive(pid)
        }

        // 3. killall
        return killall(app.processName)
    }

    /// Unload a user launch agent.
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

    /// Kill a background process by its stored PID.
    private func killProcessByPid(_ app: AppItem) -> Bool {
        guard let pid = app.pid else { return killProcessByName(app.processName) }
        kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.3)
        if !isAlive(pid) { return true }
        kill(pid, SIGKILL); Thread.sleep(forTimeInterval: 0.2)
        return !isAlive(pid)
    }

    /// Kill all processes matching the given name.
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

    private func killall(_ name: String) -> Bool {
        killProcessByName(name)
    }

    private func stopBrewService(_ app: AppItem) -> Bool {
        let name = app.processName
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-l", "-c", "brew services stop \(name)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // ──────────────────────────────────────────────
    // MARK: - Utilities
    // ──────────────────────────────────────────────
    private func isAlive(_ pid: Int32) -> Bool {
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    private func escapeAppleScript(_ str: String) -> String {
        str.replacingOccurrences(of: "\\", with: "\\\\")
           .replacingOccurrences(of: "\"", with: "\\\"")
           .replacingOccurrences(of: "\n", with: "\\n")
    }

    // ──────────────────────────────────────────────
    // MARK: - Notifications
    // ──────────────────────────────────────────────
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
