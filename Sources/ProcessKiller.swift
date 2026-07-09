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
    func killSelected(_ apps: [AppItem], trackForRestore: Bool = true) {
        let selected = apps.filter { $0.isSelected && $0.isRunning }
        guard !selected.isEmpty else { return }

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
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Restore (Public API)
    // ──────────────────────────────────────────────
    func restoreKilledApps(using apps: [AppItem]) {
        let paths = killedRestorePaths
        guard !paths.isEmpty else { return }

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
        case .service:      return killProcessByPid(app)
        case .custom:       return killProcessByPid(app)
        }
    }

    /// Gracefully quit a GUI application, then force if needed.
    private func killApplication(_ app: AppItem) -> Bool {
        // 1. AppleScript graceful quit
        let script = "tell application \"\(escapeAppleScript(app.name))\" to quit"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)

        Thread.sleep(forTimeInterval: 0.5)

        // 2. Check if still alive by PID
        if let pid = app.pid, !isAlive(pid) { return true }

        // 3. NSRunningApplication terminate
        if let bid = app.bundleIdentifier {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            running.forEach { $0.terminate() }
            Thread.sleep(forTimeInterval: 0.5)
            if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { return true }
            running.forEach { $0.forceTerminate() }
            Thread.sleep(forTimeInterval: 0.3)
            return NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
        }

        // 4. Last resort: SIGKILL via PID
        if let pid = app.pid {
            kill(pid, SIGTERM); Thread.sleep(forTimeInterval: 0.3)
            if !isAlive(pid) { return true }
            kill(pid, SIGKILL); Thread.sleep(forTimeInterval: 0.2)
            return !isAlive(pid)
        }

        // 5. Kill by process name
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
