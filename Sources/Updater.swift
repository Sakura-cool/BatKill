import Foundation
import AppKit

// MARK: - GitHub Release Model
struct GitHubRelease: Decodable {
    let tagName: String
    let name: String
    let body: String?
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, assets
    }
}

struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - Version Checker
final class VersionChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var hasUpdate = false
    @Published var isLoading = false

    private let repoAPIURL = "https://api.github.com/repos/Sakura-cool/BatKill/releases/latest"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdate() {
        isLoading = true
        guard let url = URL(string: repoAPIURL) else { return }

        var request = URLRequest(url: url)
        request.setValue("BatKill-Updater", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                self?.isLoading = false
            }
            guard let data = data,
                  let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
                logger("Updater: failed to parse release info")
                return
            }

            let remote = release.tagName.replacingOccurrences(of: "v", with: "")
            logger("Updater: current=\(self?.currentVersion ?? "?"), remote=\(remote)")

            DispatchQueue.main.async {
                self?.latestVersion = remote
                self?.hasUpdate = self?.isNewer(remote: remote) ?? false
            }
        }.resume()
    }

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
final class Updater: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var statusMessage: String?

    private let checker: VersionChecker

    init(checker: VersionChecker) {
        self.checker = checker
    }

    func downloadAndInstall() {
        guard let tagName = checker.latestVersion else { return }
        let assetName = currentArch() == "arm64" ? "BatKill-arm.app.zip" : "BatKill-x86.app.zip"
        let downloadURL = "https://github.com/Sakura-cool/BatKill/releases/download/v\(tagName)/\(assetName)"

        guard let url = URL(string: downloadURL) else { return }

        isDownloading = true
        statusMessage = "Downloading v\(tagName)..."
        downloadProgress = 0

        logger("Updater: downloading \(downloadURL)")

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                self?.isDownloading = false
            }

            guard let tempURL = tempURL, error == nil else {
                logger("Updater: download failed: \(error?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self?.statusMessage = "Download failed"
                }
                return
            }

            self?.installFromZip(tempURL: tempURL)
        }

        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        task.resume()
        _ = observation
    }

    private func installFromZip(tempURL: URL) {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("BatKill-update-\(UUID().uuidString)")

        do {
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

            try runShell("unzip -o \"\(tempURL.path)\" -d \"\(tmpDir.path)\" 2>/dev/null")

            guard let appPath = findApp(in: tmpDir) else {
                logger("Updater: no .app found in extracted zip")
                DispatchQueue.main.async { self.statusMessage = "Update failed: app not found" }
                return
            }

            let currentAppPath = Bundle.main.bundlePath

            let script = """
            #!/bin/bash
            # Wait for the running process to fully exit
            while pgrep -x BatKill > /dev/null 2>&1; do
                sleep 0.5
            done

            # Remove quarantine from the NEW app BEFORE copying (recursive)
            xattr -rd com.apple.quarantine "\(appPath.path)" 2>/dev/null || true

            # Remove old bundle
            rm -rf "\(currentAppPath)"

            # Copy clean bundle to original location
            ditto "\(appPath.path)" "\(currentAppPath)"

            # Ensure executable permission
            chmod +x "\(currentAppPath)/Contents/MacOS/BatKill"

            # Double-check: remove quarantine on final location too
            xattr -rd com.apple.quarantine "\(currentAppPath)" 2>/dev/null || true

            # Relaunch
            open "\(currentAppPath)"

            # Cleanup temp
            rm -rf "\(tmpDir.path)"
            """

            let scriptPath = tmpDir.appendingPathComponent("update.sh")
            try script.write(toFile: scriptPath.path, atomically: true, encoding: .utf8)
            try runShell("chmod +x \"\(scriptPath.path)\"")

            logger("Updater: launching background update script, then terminating")

            let bg = Process()
            bg.executableURL = URL(fileURLWithPath: "/bin/bash")
            bg.arguments = ["-c", "nohup \"\(scriptPath.path)\" > /dev/null 2>&1 &"]
            try bg.run()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }

        } catch {
            logger("Updater: install failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.statusMessage = "Install failed: \(error.localizedDescription)" }
        }
    }

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

    private func runShell(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        try process.run()
        process.waitUntilExit()
    }

    private func currentArch() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
}
