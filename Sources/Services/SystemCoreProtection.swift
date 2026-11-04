//  SystemCoreProtection.swift
//  BatKill
//
//  Protects macOS core system components from being managed (killed/suspended)
//  by BatKill. These components are essential to core computer function --
//  terminating or suspending them breaks the desktop, audio, network, or
//  security, and most (e.g. XPC helpers) have no relaunch mechanism.
//
//  Two responsibilities (v0.2.4 CHANGE-060):
//  1. `isCoreSystemComponent(...)` -- predicate used by AppLister to exclude
//     core components from the discoverable/killable list (not shown).
//  2. `cleanupPersistedConfig()` -- migration that removes any leftover config
//     referencing a core component, and unfreezes (SIGCONT) any that were
//     suspended, so stale/erroneous config no longer takes effect.

import AppKit
import Foundation

// MARK: - System Core Protection

/// Curated list and helpers for macOS core system components that must never
/// be managed by BatKill.
enum SystemCoreProtection {

    // MARK: - Core Component Lists

    /// Core macOS components identified by bundle identifier.
    /// Killing/suspending any of these breaks core GUI or system function.
    private static let coreBundleIDs: Set<String> = [
        // Desktop / GUI essentials
        "com.apple.dock",
        "com.apple.finder",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.WindowServer",
        // Audio / network / security / lifecycle daemons
        "com.apple.coreaudiod",
        "com.apple.bluetoothd",
        "com.apple.mDNSResponder",
        "com.apple.configd",
        "com.apple.securityd",
        "com.apple.networkd",
        "com.apple.syslogd",
        "com.apple.cfprefsd",
        "com.apple.runningboardd",
        "com.apple.powerd",
        "com.apple.launchd",
        "com.apple.dock.extra"
    ]

    /// Core macOS components identified by process name (no reliable bundle ID,
    /// or discovery is unstable). Killing these breaks core function.
    private static let coreProcessNames: Set<String> = [
        "WindowServer",
        "loginwindow",
        "coreaudiod",
        "bluetoothd",
        "mDNSResponder",
        "configd",
        "securityd",
        "networkd",
        "syslogd",
        "cfprefsd",
        "runningboardd",
        "powerd",
        "launchd",
        "Dock",
        "DockHelper",
        "com.apple.dock.extra"
    ]

    // MARK: - Predicate

    /// Returns true if the given component is a core macOS system component
    /// that must never be managed (killed/suspended) by BatKill.
    static func isCoreSystemComponent(path: String, bundleIdentifier: String?, processName: String) -> Bool {
        // 1. Explicit bundle ID match.
        if let bid = bundleIdentifier, coreBundleIDs.contains(bid) {
            return true
        }
        // 2. Explicit process name match.
        if coreProcessNames.contains(processName) {
            return true
        }
        // 3. Core system services directory (Dock / Finder / loginwindow /
        //    SystemUIServer / ControlCenter / ...).
        if path.hasPrefix("/System/Library/CoreServices/") {
            return true
        }
        // 4. System XPC helper services under /System -- these have no
        //    independent launch mechanism, so they cannot be restored after
        //    being killed.
        if path.contains("/XPCServices/") && path.hasPrefix("/System/") {
            return true
        }
        return false
    }

    // MARK: - Persisted Config Cleanup (Migration)

    /// Removes any persisted config referencing a core system component, and
    /// unfreezes (SIGCONT) any that were suspended so stale/erroneous config
    /// no longer takes effect and the system component is left working.
    /// Idempotent -- safe to run on every launch.
    static func cleanupPersistedConfig() {
        let defaults = UserDefaults.standard

        // 1. Unfreeze any suspended core components before removing them from
        //    the suspended set, so they are not left frozen by stale config.
        let suspended = defaults.stringArray(forKey: "suspendedPaths") ?? []
        let suspendedToResume = suspended.filter(isCorePath)
        for path in suspendedToResume {
            resumeIfFrozen(path)
        }
        if !suspendedToResume.isEmpty {
            let remaining = suspended.filter { !isCorePath($0) }
            defaults.set(remaining, forKey: "suspendedPaths")
        }

        // 2. Remove core components from the selected-apps list.
        let selected = defaults.stringArray(forKey: "selectedAppPaths") ?? []
        let selectedFiltered = selected.filter { !isCorePath($0) }
        if selectedFiltered != selected {
            defaults.set(selectedFiltered, forKey: "selectedAppPaths")
        }

        // 3. Remove core components from the pending-restore list.
        let killed = defaults.stringArray(forKey: "killedRestorePaths") ?? []
        let killedFiltered = killed.filter { !isCorePath($0) }
        if killedFiltered != killed {
            defaults.set(killedFiltered, forKey: "killedRestorePaths")
        }

        // 4. Remove core components from per-app suspend strategies.
        if let strategies = defaults.dictionary(forKey: "appSuspendStrategies") as? [String: String] {
            let filtered = strategies.filter { !isCorePath($0.key) }
            if filtered.count != strategies.count {
                defaults.set(filtered, forKey: "appSuspendStrategies")
            }
        }
    }

    // MARK: - Helpers

    /// Matches a persisted path (`.app` / `.xpc` / executable) against the
    /// core-component predicate, deriving the process name from the path.
    private static func isCorePath(_ path: String) -> Bool {
        let procName = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: ".xpc", with: "")
            .replacingOccurrences(of: ".app", with: "")
        return isCoreSystemComponent(path: path, bundleIdentifier: nil, processName: procName)
    }

    /// Sends `SIGCONT` to a frozen process identified by its bundle path, so a
    /// core component left suspended by stale config resumes running.
    private static func resumeIfFrozen(_ path: String) {
        // Prefer NSWorkspace to resolve the PID by bundle path.
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == path {
            kill(app.processIdentifier, SIGCONT)
            return
        }
        // Fallback: resolve by process name via pgrep, then SIGCONT.
        let procName = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: ".xpc", with: "")
            .replacingOccurrences(of: ".app", with: "")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", procName]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let pidStr = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pid = pidStr.flatMap({ Int32($0) }) {
            kill(pid, SIGCONT)
        }
    }
}
