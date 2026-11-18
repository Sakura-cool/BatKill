//  Logger.swift
//  BatKill
//
//  Shared file-based logger for the BatKill application.
//
//  Design (v0.2.6, 真机反馈 — 日志 I/O / 存储 / 分级):
//  - Log LEVELS: `debug` / `info` / `warning` / `error`, tagged in each line
//    (`[HH:mm:ss] [LEVEL] message`) so debug and info are distinguishable.
//  - DEBUG is compiled in ONLY for development builds (`-DDEBUG`); release
//    builds compile it out entirely (never emitted, gesture toggle inert).
//    INFO is the routine level (always recorded).
//  - Aggregated, BUFFERED writes: messages accumulate in an in-memory buffer
//    and flush in a batch (either when the buffer reaches `maxBufferSize`, or
//    a debounce after the last message) — no scattered per-line disk writes,
//    which waste disk I/O.
//  - COMPRESSION + retention: the active log is rotated when it exceeds
//    `maxLogSize`; rotated files are gzip-compressed (zlib) to save storage,
//    and files older than `retentionDays` are deleted (age-based cleanup) so
//    stale logs never accumulate.
//
//  Usage:
//    logger("routine event")     // INFO (always)
//    debugLog("detail")          // DEBUG (dev builds only)
//    criticalLog("error")        // ERROR + immediate flush
//
//  View:   tail -f ~/Library/Logs/BatKill/batkill.log
//
//  Extracted from: BatteryMonitor.swift

import Foundation
import zlib

// MARK: - Log File Location

/// 日志文件位置（v0.1.6 FIX-003）。
///
/// 0.1.5 及以前固定写 `/tmp/batkill.log`：`/tmp` 是全局可写目录且文件名可预测，
/// 存在符号链接劫持（覆盖任意可写文件）与同机其他用户可读的信息泄漏风险。
/// 现在写入用户私有目录 `~/Library/Logs/BatKill/`（目录权限 0700）；
/// 若该目录不可写（如受限环境），降级到系统临时目录，保证日志功能不中断。
enum LogFile {
    /// 降级路径：仅当用户私有目录不可写时使用。
    static let fallbackURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("batkill.log", isDirectory: false)

    /// 日志目录（用于轮转/清理扫描）。
    static let directoryURL: URL = {
        let manager = FileManager.default
        let base = manager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        let directory = base.appendingPathComponent("Logs/BatKill", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            // 目录已存在时也把权限收紧到 0700
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return FileManager.default.temporaryDirectory
        }
        guard manager.isWritableFile(atPath: directory.path) else {
            return FileManager.default.temporaryDirectory
        }
        return directory
    }()

    /// 实际使用的日志文件路径（进程内固定，避免日志分散到两个文件）。
    static let url: URL = directoryURL.appendingPathComponent("batkill.log", isDirectory: false)

    /// 日志文件路径字符串。
    static var path: String { url.path }
}

// MARK: - Log Level

/// Log severity. Higher raw value = more severe. Each line is tagged with the
/// level so debug and info are distinguishable in the log file (v0.2.6).
enum LogLevel: Int, Comparable, CustomStringConvertible {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var description: String {
        switch self {
        case .debug:   return "DEBUG"
        case .info:    return "INFO"
        case .warning: return "WARN"
        case .error:   return "ERROR"
        }
    }
}

// MARK: - Debug Logging Control (compile-time gated)

/// Controls whether debug-level logging is emitted.
///
/// Debug logging is **only available in development builds** (`-DDEBUG`):
/// release builds compile the `#if DEBUG` branches out, so debug logs are
/// never emitted and the runtime toggle is inert. In dev builds debug is
/// enabled by default and can be toggled off/on via the rapid-click gesture.
enum DebugLogger {
    /// Whether debug logging is currently enabled. Compile-time gated:
    /// `true` in `-DDEBUG` (dev) builds, `false` in release builds.
    static var isEnabled: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Toggles debug logging on/off. No-op in release builds (debug compiled out).
    static func toggle() {
        #if DEBUG
        isEnabled.toggle()
        let state = isEnabled ? "ENABLED" : "DISABLED"
        // Use direct write for toggle confirmation (bypasses queue)
        directLog("🔧 Debug logging \(state)", level: .info)
        #endif
    }
}

// MARK: - Log Rotation & Retention (pure helpers)

/// Size rotation + age-based retention + gzip compression for the log file.
/// Pure/static so the logic is unit-testable without touching disk state.
enum LogRotation {
    /// Active log rotates when it exceeds this size (512 KB).
    static let maxLogSize: UInt64 = 512 * 1024

    /// Number of rotated (gzipped) files kept before the oldest is dropped.
    static let maxRotatedFiles = 3

    /// Rotated files older than this many days are deleted (age-based cleanup).
    static let retentionDays = 7

    /// Whether the active log (of `currentSize` bytes) should be rotated.
    static func shouldRotate(currentSize: UInt64) -> Bool {
        currentSize >= maxLogSize
    }

    /// Gzip-compresses `data` (zlib) for a rotated log file.
    /// Returns nil on empty input or compression failure.
    static func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let bytes = [UInt8](data)
        let path = tempPath()
        guard let gz = gzopen(path, "wb") else { return nil }
        var writeOK = true
        var offset = 0
        while offset < bytes.count {
            let chunk = min(bytes.count - offset, 1 << 20)
            let written: Int32 = bytes.withUnsafeBufferPointer { p in
                guard let base = p.baseAddress else { return 0 }
                return gzwrite(gz, base + offset, UInt32(chunk))
            }
            guard written > 0 else { writeOK = false; break }
            offset += Int(written)
        }
        // Close exactly once (flushes the gzip trailer) before reading back.
        gzclose(gz)
        guard writeOK,
              let gzData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            try? FileManager.default.removeItem(atPath: path)
            return nil
        }
        try? FileManager.default.removeItem(atPath: path)
        return gzData
    }

    /// Temp path used by `gzipCompress` (deleted after each use).
    private static func tempPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("batkill-rotate-\(UUID().uuidString).gz", isDirectory: false).path
    }
}

// MARK: - Log Queue (Batch Writer + Rotation + Retention)

/// Buffered log queue that batches writes to reduce disk I/O.
/// Accumulates messages and flushes them as a batch when the buffer reaches
/// `maxBufferSize`, or after a short debounce (so low-volume logs still land
/// on disk). On flush the active log is rotated if oversized (gzip the old
/// file), and stale rotated files are cleaned by age.
final class LogQueue {
    /// Shared singleton instance.
    static let shared = LogQueue()

    /// Serial queue for thread-safe buffer access.
    private let queue = DispatchQueue(label: "com.batkill.logqueue")

    /// Buffer for pending log messages.
    private var buffer: [String] = []

    /// Maximum number of messages before auto-flush (aggregated batch).
    private let maxBufferSize = 20

    /// Debounce: flush `debounceInterval` after the last message if the buffer
    /// is non-empty (ensures low-volume logs are not stranded in memory).
    private static let debounceInterval: TimeInterval = 5.0
    private var debounceWork: DispatchWorkItem?

    /// Log file path.
    private let logPath = LogFile.path

    /// Whether the queue is currently flushing.
    private var isFlushing = false

    private init() {
        // Flush any remaining buffered lines on normal process exit.
        atexit { LogQueue.shared.flushSync() }
        // Age-based cleanup of stale rotated logs at startup (v0.2.6).
        cleanupStaleLogs()
    }

    deinit {
        flush() // Final flush on dealloc
    }

    /// Adds a level-tagged message to the buffer. Triggers a batch flush when
    /// the buffer is full, or schedules a debounced flush for low volume.
    func enqueue(_ message: String, level: LogLevel) {
        let timestamped = formatTimestamp(message, level: level)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.buffer.append(timestamped)
            self.scheduleDebouncedFlush()
            if self.buffer.count >= self.maxBufferSize {
                self.flushLocked()
            }
        }
    }

    /// Flushes all buffered messages to disk (async).
    func flush() {
        queue.async { [weak self] in
            self?.flushLocked()
        }
    }

    /// Forces an immediate synchronous flush (for critical messages / exit).
    func flushSync() {
        queue.sync { [weak self] in
            self?.flushLocked()
        }
    }

    /// Schedules a debounced flush so low-volume logs are written promptly
    /// without a scattered write per message.
    private func scheduleDebouncedFlush() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    /// Internal flush (must be called on queue).
    private func flushLocked() {
        guard !isFlushing, !buffer.isEmpty else { return }
        isFlushing = true

        let messages = buffer
        buffer = []

        // Rotate BEFORE writing so the newest batch always lands in the active
        // log: rotating after the write would gzip the just-written lines into
        // .gz, making recent output disappear from the tail-followed active file.
        rotateIfNeeded()

        let data = messages.joined(separator: "\n").appending("\n").data(using: .utf8)
        if let data {
            if let fh = FileHandle(forWritingAtPath: logPath) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
            }
        }

        isFlushing = false
    }

    /// Rotates the active log if it exceeds `maxLogSize`: shifts existing
    /// gzipped rotations, gzips the current file, and starts a fresh one.
    /// Also runs age-based cleanup (so stale logs never accumulate).
    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
              let size = attrs[.size] as? UInt64,
              LogRotation.shouldRotate(currentSize: size) else { return }

        // Shift existing gzipped rotations: .2.gz -> .3.gz, .1.gz -> .2.gz.
        for i in stride(from: LogRotation.maxRotatedFiles, through: 2, by: -1) {
            let src = "\(logPath).\(i - 1).gz"
            let dst = "\(logPath).\(i).gz"
            if FileManager.default.fileExists(atPath: src) {
                try? FileManager.default.moveItem(atPath: src, toPath: dst)
            }
        }
        // Gzip the current log into .1.gz and start fresh.
        if let data = try? Data(contentsOf: URL(fileURLWithPath: logPath)),
           let gz = LogRotation.gzipCompress(data) {
            try? gz.write(to: URL(fileURLWithPath: "\(logPath).1.gz"), options: .atomic)
            try? FileManager.default.removeItem(atPath: logPath)
        }
        cleanupStaleLogs()
    }

    /// Deletes rotated log files older than `retentionDays` (age-based cleanup).
    /// Called at startup and after each rotation. Bounded: only touches files
    /// in the BatKill log directory with the `batkill.log` prefix.
    private func cleanupStaleLogs() {
        let cutoff = Date().addingTimeInterval(-Double(LogRotation.retentionDays) * 86_400)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: LogFile.directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in files
        where url.lastPathComponent.hasPrefix("batkill.log") && url.pathExtension == "gz" {
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Formats a message with a timestamp and level tag.
    private static let logDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private func formatTimestamp(_ msg: String, level: LogLevel) -> String {
        let ts = Self.logDateFormatter.string(from: Date())
        return "[\(ts)] [\(level.description)] \(msg)"
    }
}

// MARK: - Public Logger Functions

/// Logs a routine (INFO) message. Always recorded.
func logger(_ msg: String) {
    LogQueue.shared.enqueue(msg, level: .info)
}

/// Logs a debug message. Emitted only in development builds (`-DDEBUG`);
/// no-op in release builds.
func debugLog(_ msg: String) {
    guard DebugLogger.isEnabled else { return }
    LogQueue.shared.enqueue(msg, level: .debug)
}

/// Logs a warning (WARN) message. Always recorded.
func warnLog(_ msg: String) {
    LogQueue.shared.enqueue(msg, level: .warning)
}

/// Logs a critical (ERROR) message and forces immediate flush.
/// Use for crash-critical information that must be written immediately.
func criticalLog(_ msg: String) {
    LogQueue.shared.enqueue(msg, level: .error)
    LogQueue.shared.flushSync()
}

/// Direct synchronous write for toggle confirmations and critical startup
/// messages. Bypasses the queue for immediate visibility.
private func directLog(_ msg: String, level: LogLevel) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] [\(level.description)] \(msg)\n"
    let path = LogFile.path
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

// MARK: - Operation Context (Structured Logging)

/// Structured operation context for correlating logs within a single operation.
/// Provides log correlation, duration tracking, and hierarchical nesting.
///
/// Usage:
///   let ctx = LogContext(name: "killSelected")
///   ctx.log("开始终止 \(apps.count) 个应用")
///   // ... perform operation ...
///   ctx.complete(success: true)
///
/// Output:
///   [killSelected] 开始终止 3 个应用
///   ✅ killSelected: 完成 (2.35s)
final class LogContext {
    /// Short unique identifier for this operation (first 8 chars of UUID).
    let id: String

    /// Human-readable operation name.
    let name: String

    /// Operation start timestamp.
    let startTime: Date

    /// Parent operation name (for nested contexts).
    let parentName: String?

    /// Creates a new operation context.
    /// - Parameters:
    ///   - name: Operation name (used in log messages).
    ///   - parent: Optional parent operation name (for nesting).
    init(name: String, parent: String? = nil) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.name = name
        self.startTime = Date()
        self.parentName = parent
    }

    /// Logs a message within this operation context (INFO level).
    /// - Parameter message: The message to log.
    func log(_ message: String) {
        let prefix = parentName.map { "[\($0)→\(name)]" } ?? "[\(name)]"
        logger("\(prefix) \(message)")
    }

    /// Logs a debug message within this operation context.
    /// Only logs in development builds (debug level).
    /// - Parameter message: The debug message to log.
    func debug(_ message: String) {
        let prefix = parentName.map { "[\($0)→\(name)]" } ?? "[\(name)]"
        debugLog("\(prefix) \(message)")
    }

    /// Marks the operation as complete and logs the result (INFO level).
    /// - Parameters:
    ///   - success: Whether the operation succeeded.
    ///   - extra: Optional additional information.
    func complete(success: Bool, extra: String? = nil) {
        let duration = Date().timeIntervalSince(startTime)
        let status = success ? "✅" : "❌"
        let detail = extra.map { " (\($0))" } ?? ""
        logger("\(status) \(name): \(success ? "完成" : "失败") (\(formatDuration(duration))\(detail)")
    }

    /// Logs an error and marks the operation as failed.
    /// - Parameter error: The error description.
    func fail(_ error: String) {
        complete(success: false, extra: error)
    }

    /// Creates a child context for nested operations.
    /// - Parameter childName: Name of the child operation.
    /// - Returns: A new LogContext with this operation as parent.
    func child(_ childName: String) -> LogContext {
        let fullParent = [parentName, name].compactMap { $0 }.joined(separator: "→")
        return LogContext(name: childName, parent: fullParent)
    }

    /// Formats a time interval into a human-readable string.
    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1.0 {
            return String(format: "%.0fms", duration * 1000)
        } else {
            return String(format: "%.2fs", duration)
        }
    }
}
