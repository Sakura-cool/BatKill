//  FanInstallManager.swift
//  BatKill
//
//  One-time privileged installer for the batkill-fan sudo channel (CHANGE-019).
//
//  Replaces the dead AEWP path: installs the standalone `batkill-fan` CLI
//  into a root-owned directory and writes a parameter-scoped NOPASSWD
//  sudoers rule, so the app can write fan speeds via `sudo -n` with zero
//  further prompts.

import Foundation

/// Installs / uninstalls the privileged fan-write channel.
enum FanInstallManager {

    /// Absolute path of the installed CLI (root-owned directory, not PATH).
    static let cliPath = "/usr/local/BatKill/batkill-fan"

    /// sudoers rule filename (no dots — sudo ignores files with dots).
    static let sudoersName = "batkill-fan"

    static let sudoersPath = "/etc/sudoers.d/\(sudoersName)"

    /// The app bundle's own copy of the CLI (embedded for installation).
    private static var bundledCLIPath: String? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/batkill-fan").path
    }

    /// Whether the CLI exists and the sudoers rule is present.
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: cliPath)
            && FileManager.default.fileExists(atPath: sudoersPath)
    }

    /// Whether the current user can already run the CLI without a prompt
    /// (`sudo -n -l` returns the NOPASSWD entry when present).
    static func isSudoReady() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "-l", cliPath]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// One-time install: copies the CLI and writes the sudoers rule using a
    /// single `osascript … with administrator privileges` prompt.
    ///
    /// The shell script is base64-encoded so special characters in the rule
    /// (`$`, `^`, `[]`) survive both AppleScript and shell quoting.
    static func install(completion: @escaping (Bool) -> Void) {
        guard let bundled = bundledCLIPath,
              FileManager.default.fileExists(atPath: bundled) else {
            logger("FanInstall: 找不到内置 batkill-fan（Resources 缺失）")
            completion(false)
            return
        }

        let user = NSUserName()
        // fnmatch wildcards (not ERE): macOS's sudo is not compiled with
        // POSIX ERE argument support, so `^[0-9]+$` is treated literally
        // and never matches. `[0-9]*` / `[01]` are baseline glob features.
        let rule = "\(user) ALL=(root) NOPASSWD: \(cliPath) --set-fan [0-9]* [0-9]*\n"
            + "\(user) ALL=(root) NOPASSWD: \(cliPath) --set-fan-mode [0-9]* [01]\n"
        guard let ruleData = rule.data(using: .utf8) else {
            logger("FanInstall: 规则编码失败")
            completion(false)
            return
        }
        let ruleB64 = ruleData.base64EncodedString()

        // Script runs as root via the admin prompt.
        let script = """
        set -e
        mkdir -p /usr/local/BatKill
        cp '\(bundled)' \(cliPath)
        chown root:wheel \(cliPath)
        chmod 755 \(cliPath)
        xattr -dr com.apple.quarantine \(cliPath) 2>/dev/null || true
        echo \(ruleB64) | base64 --decode > \(sudoersPath)
        chown root:wheel \(sudoersPath)
        chmod 0440 \(sudoersPath)
        visudo -c -f \(sudoersPath)
        """

        let escaped = script.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", appleScript]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                let ok = p.terminationStatus == 0 && isSudoReady()
                logger("FanInstall: \(ok ? "成功" : "失败（exit \(p.terminationStatus)）")")
                DispatchQueue.main.async { completion(ok) }
            } catch {
                logger("FanInstall: 启动 osascript 失败 \(error.localizedDescription)")
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Removes the CLI and the sudoers rule (one admin prompt).
    static func uninstall(completion: @escaping (Bool) -> Void) {
        let script = "rm -f \(cliPath) \(sudoersPath); rmdir /usr/local/BatKill 2>/dev/null || true"
        let appleScript = "do shell script \"\(script)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", appleScript]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                DispatchQueue.main.async { completion(p.terminationStatus == 0) }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }
}
