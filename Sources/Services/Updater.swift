//  Updater.swift
//  BatKill
//
//  In-app update system that checks for new releases on GitHub, compares
//  version numbers, downloads the architecture-appropriate dmg, and
//  performs a hot-swap installation (download -> mount dmg -> copy bundle
//  -> replace -> relaunch).
//
//  Components:
//  - GitHubRelease / ReleaseAsset: Decodable models for the GitHub Releases API
//  - VersionChecker: Async version comparison (current vs. latest release)
//  - Updater: Download, extract, and install with progress tracking

import Foundation
import AppKit

// MARK: - GitHub Release Model

/// Decodable model for a GitHub release object from the REST API.
/// Maps JSON fields to Swift properties using custom CodingKeys for
/// snake_case -> camelCase conversion.
struct GitHubRelease: Decodable {
    /// Git tag name (e.g., "v0.0.13").
    let tagName: String
    /// Human-readable release title.
    let name: String
    /// Release notes body (may contain Markdown).
    let body: String?
    /// Attached binary assets (dmg files for arm64/x86_64).
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

/// Decodable model for a release asset (downloadable file) attached to
/// a GitHub release.
struct ReleaseAsset: Decodable {
    /// Filename (e.g., "BatKill-arm64.dmg").
    let name: String
    /// Direct download URL for the asset.
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - Version Checker

/// Checks the GitHub releases API for new versions and compares them
/// against the currently running app version.
///
/// Publishes `hasUpdate` to drive the UI's update badge. Call
/// `checkForUpdate()` to trigger an async check.
final class VersionChecker: ObservableObject {
    /// The latest version string from GitHub (nil until first check).
    @Published var latestVersion: String?

    /// Whether a newer version is available.
    @Published var hasUpdate = false

    /// Whether a network check is in progress.
    @Published var isLoading = false

    /// GitHub API endpoint for the latest release.
    private let repoAPIURL = "https://api.github.com/repos/Sakura-cool/BatKill/releases/latest"

    /// The app's current version from Info.plist (CFBundleShortVersionString).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Result of a manual update check.
    enum CheckResult {
        /// A newer version is available (`latestVersion` is now set).
        case hasUpdate
        /// The installed version is already the latest.
        case upToDate
        /// The check failed (network / parse error).
        case failed
    }

    /// Fetches the latest release from GitHub and compares version numbers.
    /// Updates `latestVersion` and `hasUpdate` on the main thread.
    /// - Parameter completion: Called on the main thread with the check result.
    ///   Omit to keep the existing fire-and-forget behavior.
    func checkForUpdate(completion: ((CheckResult) -> Void)? = nil) {
        isLoading = true
        guard let url = URL(string: repoAPIURL) else {
            DispatchQueue.main.async {
                self.isLoading = false
                completion?(.failed)
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("BatKill-Updater", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.isLoading = false
            }
            guard let data = data,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                logger("Updater: failed to parse release info")
                DispatchQueue.main.async {
                    completion?(.failed)
                }
                return
            }

            // Strip "v" prefix for numeric comparison
            let remote = release.tagName.replacingOccurrences(of: "v", with: "")
            logger("Updater: current=\(self.currentVersion), remote=\(remote)")

            DispatchQueue.main.async {
                self.latestVersion = remote
                let newer = self.isNewer(remote: remote)
                self.hasUpdate = newer
                completion?(newer ? .hasUpdate : .upToDate)
            }
        }.resume()
    }

    /// Compares a remote version string against the local version using
    /// semantic versioning (major.minor.patch), component by component.
    private func isNewer(remote: String) -> Bool {
        let local = currentVersion.split(separator: ".").map { Int($0) ?? 0 }
        let remoteParts = remote.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(local.count, remoteParts.count)
        for i in 0..<count {
            let l = i < local.count ? local[i] : 0
            let r = i < remoteParts.count ? remoteParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }
}

// MARK: - Updater

/// Handles the full update lifecycle: download, mount, install, relaunch.
    ///
    /// The installation process:
    /// 1. Downloads the architecture-appropriate dmg from GitHub Releases
    /// 2. Mounts the dmg and copies the .app to a temporary directory
    /// 3. Writes a background shell script that:
    ///    a. Waits for the current process to exit
    ///    b. Removes quarantine attributes from the new bundle
    ///    c. Replaces the old bundle with `ditto`
    ///    d. Ensures executable permissions
    ///    e. Removes quarantine on the final location
    ///    f. Relaunches the app and cleans up
    /// 4. Launches the script in the background
    /// 5. Terminates the current process
final class Updater: ObservableObject {
    /// App name, used for constructing paths in the update process.
    private let APP_NAME = "BatKill"

    /// Whether a download is currently in progress.
    @Published var isDownloading = false

    /// Download progress as a fraction (0.0 - 1.0).
    @Published var downloadProgress: Double = 0

    /// User-facing status message (e.g., "Downloading v0.0.14...").
    @Published var statusMessage: String?

    private var progressObservation: NSKeyValueObservation?

    /// Reference to the version checker for accessing the latest version.
    private let checker: VersionChecker

    /// - Parameter checker: The version checker providing the target version.
    init(checker: VersionChecker) {
        self.checker = checker
    }

    /// Downloads the latest release dmg and installs it.
    /// Selects the correct asset (arm64 vs x86_64) based on the
    /// current architecture.
    func downloadAndInstall() {
        guard let tagName = checker.latestVersion else { return }
        let assetName = "BatKill-\(currentArch()).dmg"
        let downloadURL = "https://github.com/Sakura-cool/BatKill/releases/download/v\(tagName)/\(assetName)"

        guard let url = URL(string: downloadURL) else { return }

        isDownloading = true
        statusMessage = "Downloading v\(tagName)..."
        downloadProgress = 0

        logger("Updater: downloading \(downloadURL)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self else { return }

            if let error {
                logger("Updater: download failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.statusMessage = "Download failed: \(error.localizedDescription)"
                }
                return
            }

            guard let httpResp = response as? HTTPURLResponse, (200..<300).contains(httpResp.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                logger("Updater: download HTTP error \(code)")
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.statusMessage = "Download failed (HTTP \(code))"
                }
                return
            }

            guard let tempURL else {
                logger("Updater: download returned nil temp URL")
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.statusMessage = "Download failed: no file"
                }
                return
            }

            logger("Updater: download OK, installing from \(tempURL.path)")
            DispatchQueue.main.async {
                self.statusMessage = "Installing..."
            }
            self.installFromDmg(tempURL: tempURL)
        }

        self.progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        task.resume()
    }

    /// Mounts the downloaded dmg, copies the .app bundle, writes
    /// an update script, launches it in the background, and terminates
    /// the current process.
    private func installFromDmg(tempURL: URL) {
        let mountPoint = FileManager.default.temporaryDirectory.appendingPathComponent("BatKill-mount-\(UUID().uuidString)")
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("BatKill-update-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            // Mount dmg（v0.1.6 FIX-001：具体二进制 + 参数数组，不经 shell）
            try ProcessRunner.run(executable: "/usr/bin/hdiutil",
                                  arguments: ["attach", tempURL.path, "-nobrowse",
                                              "-mountpoint", mountPoint.path])

            // Find .app in mounted volume
            guard let appPath = findApp(in: mountPoint) else {
                _ = try? ProcessRunner.run(executable: "/usr/bin/hdiutil",
                                           arguments: ["detach", mountPoint.path])
                logger("Updater: no .app found in dmg")
                DispatchQueue.main.async { self.statusMessage = "Update failed: app not found" }
                return
            }

            let newAppPath = tmpDir.appendingPathComponent(appPath.lastPathComponent)
            try ProcessRunner.run(executable: "/usr/bin/ditto",
                                  arguments: [appPath.path, newAppPath.path])

            // Detach dmg
            _ = try? ProcessRunner.run(executable: "/usr/bin/hdiutil",
                                       arguments: ["detach", mountPoint.path])

            let currentAppPath = Bundle.main.bundlePath

            // Background update script: wait for exit, replace bundle, relaunch
            // v0.1.6 FIX-001：路径一律经参数传入（$1/$2/$3），脚本正文不插值外部数据
            let script = """
            #!/bin/bash
            # $1 = 新 app 路径　$2 = 当前 app 路径　$3 = 临时目录
            # Wait for the running process to fully exit
            while pgrep -x BatKill > /dev/null 2>&1; do
                sleep 0.5
            done

            # Remove quarantine from the NEW app BEFORE copying (recursive)
            xattr -rd com.apple.quarantine "$1" 2>/dev/null || true

            # Remove old bundle
            rm -rf "$2"

            # Copy clean bundle to original location
            ditto "$1" "$2"

            # Ensure executable permission
            chmod +x "$2/Contents/MacOS/BatKill"

            # Double-check: remove quarantine on final location too
            xattr -rd com.apple.quarantine "$2" 2>/dev/null || true

            # Relaunch
            open "$2"

            # Cleanup temp
            rm -rf "$3"
            """

            let scriptPath = tmpDir.appendingPathComponent("update.sh")
            try script.write(toFile: scriptPath.path, atomically: true, encoding: .utf8)
            // 可执行权限：用 FileManager 设置（替代 `chmod +x` 进程调用）
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptPath.path)

            logger("Updater: launching background update script, then terminating")

            // Launch the update script detached from the current process.
            // 脚本带 shebang，直接执行（不经 `bash -c` 命令文本），参数数组传递。
            _ = try ProcessRunner.runDetached(executable: scriptPath.path,
                                              arguments: [newAppPath.path,
                                                          currentAppPath,
                                                          tmpDir.path])

            // Give the background script time to start, then terminate
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }

        } catch {
            logger("Updater: install failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.statusMessage = "Install failed: \(error.localizedDescription)" }
        }
    }

    /// Recursively searches a directory for the first `.app` bundle.
    /// Used to find the extracted application in the temporary directory.
    private func findApp(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        for item in contents {
            if item.pathExtension == "app" {
                return item
            }
            if item.hasDirectoryPath {
                if let found = findApp(in: item) {
                    return found
                }
            }
        }
        return nil
    }

    /// Returns the current CPU architecture string ("arm64" or "x86_64").
    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
