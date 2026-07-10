import Cocoa
import Foundation

/// Enumerates user-installed apps, launch agents, and background services.
final class AppLister: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var isLoading = false
    @Published var hasLoaded = false

    private let selectedPathsKey = "selectedAppPaths"
    private let isSystemPathsKey = "knownSystemPaths"

    // ──────────────────────────────────────────────
    // MARK: - Persisted Selection
    // ──────────────────────────────────────────────
    private var selectedPaths: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: selectedPathsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: selectedPathsKey) }
    }

    // ──────────────────────────────────────────────
    // MARK: - Public API
    // ──────────────────────────────────────────────
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

    func toggleApp(_ app: AppItem) {
        guard let idx = apps.firstIndex(where: { $0.id == app.id }) else { return }
        var mutable = apps[idx]
        mutable.isSelected.toggle()
        apps[idx] = mutable // replaces element → triggers @Published

        let path = apps[idx].id
        var paths = selectedPaths
        if apps[idx].isSelected { paths.insert(path) }
        else { paths.remove(path) }
        selectedPaths = paths
    }

    // ──────────────────────────────────────────────
    // MARK: - App Discovery
    // ──────────────────────────────────────────────
    private func buildAppList(savedPaths: Set<String>) -> [AppItem] {
        var seen = Set<String>()
        var result: [AppItem] = []
        let fm = FileManager.default

        // ── 1. Scan Applications directories ──
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

        // ── 2. Running apps not in standard directories ──
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

        // ── 3. Launch Agents (~/Library/LaunchAgents) ──
        let agentDir = NSHomeDirectory() + "/Library/LaunchAgents"
        if let contents = try? fm.contentsOfDirectory(atPath: agentDir) {
            for item in contents where item.hasSuffix(".plist") {
                let fullPath = "\(agentDir)/\(item)"
                let name = (item as NSString).deletingPathExtension
                let agentId = "launchagent:\(name)"
                guard seen.insert(agentId).inserted else { continue }

                let (running, pid) = processRuntimeInfo(name)
                result.append(AppItem(
                    name: name,
                    bundleIdentifier: nil,
                    path: fullPath,
                    processName: name,
                    isRunning: running,
                    isSelected: savedPaths.contains(agentId),
                    isSystemApp: false,
                    category: .launchAgent,
                    pid: pid
                ))
            }
        }

        // ── 4. User launchd services ──
        let userServices = self.userLaunchdServices()
        for svc in userServices {
            let svcId = "service:\(svc.name)"
            guard seen.insert(svcId).inserted else { continue }
            result.append(AppItem(
                name: svc.name,
                bundleIdentifier: nil,
                path: "/usr/local/opt/\(svc.name)",
                processName: svc.name,
                isRunning: true,
                isSelected: savedPaths.contains(svcId),
                isSystemApp: false,
                category: .service,
                pid: svc.pid
            ))
        }

        // ── 5. Brew installed services (running) ──
        let brewServices = self.brewRunningServices()
        for svc in brewServices {
            let brewId = "brew:\(svc.name)"
            guard seen.insert(brewId).inserted else { continue }
            result.append(AppItem(
                name: svc.name,
                bundleIdentifier: nil,
                path: "/opt/homebrew/opt/\(svc.name)",
                processName: svc.name,
                isRunning: true,
                isSelected: savedPaths.contains(brewId),
                isSystemApp: false,
                category: .service,
                pid: svc.pid
            ))
        }

        // ── Sort: running first, then A–Z ──
        result.sort { a, b in
            if a.isRunning != b.isRunning { return a.isRunning && !b.isRunning }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        return result
    }

    // ──────────────────────────────────────────────
    // MARK: - Helpers
    // ──────────────────────────────────────────────
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

    /// Returns user-space services currently registered with launchd.
    private func userLaunchdServices() -> [(name: String, pid: Int32)] {
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
        var services: [(String, Int32)] = []

        for line in output.components(separatedBy: .newlines).dropFirst() {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            // format: PID    Status  Label
            if parts.count >= 3,
               let pid = Int32(parts[0]),
               parts[1] != "-",
               !parts[2].hasPrefix("com.apple.") { // skip Apple system services
                let label = parts[2]
                let name = label.components(separatedBy: ".").last ?? label
                services.append((name, pid))
            }
        }
        return services
    }

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

    private func brewRunningServices() -> [(name: String, pid: Int32)] {
        let output = shellExec("ps -eo pid,args | grep /opt/homebrew/ | grep -v grep")
        var seenNames = Set<String>()
        var services: [(String, Int32)] = []

        for line in output.components(separatedBy: .newlines) where !line.isEmpty {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count >= 2,
                  let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let cmd = String(parts[1])

            guard let range = cmd.range(of: "/opt/homebrew/") else { continue }
            let rest = String(cmd[range.upperBound...])
            let components = rest.split(separator: "/")
            guard !components.isEmpty else { continue }

            var name = String(components[0])
            if name == "opt", components.count > 1 {
                name = String(components[1])
            } else if name == "bin" || name == "sbin", components.count > 1 {
                name = String(components[1].split(separator: " ").first ?? components[1])
            } else {
                name = String(name.split(separator: " ").first.map(String.init) ?? name)
            }

            guard !name.isEmpty, seenNames.insert(name).inserted else { continue }
            services.append((name, pid))
        }
        return services
    }
}
