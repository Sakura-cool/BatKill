//  Logger.swift
//  BatKill
//
//  Shared file-based logger for the BatKill application.
//  Uses a buffered queue to batch-write logs to disk, reducing I/O overhead.
//  Debug logging is disabled by default and can be enabled via rapid-click
//  gesture on the menu bar icon (5 clicks within 2 seconds).
//
//  Usage:
//    logger("Some event happened")  // Always logs (if debug enabled)
//    debugLog("Detailed info")      // Only logs when debug enabled
//
//  View:   tail -f /tmp/batkill.log
//
//  Extracted from: BatteryMonitor.swift

import Foundation

// MARK: - Log Queue (Batch Writer)

/// Buffered log queue that batches writes to reduce disk I/O.
/// Accumulates log messages and flushes them periodically or when
/// the buffer reaches a threshold.
final class LogQueue {
    /// Shared singleton instance.
    static let shared = LogQueue()
    
    /// Serial queue for thread-safe buffer access.
    private let queue = DispatchQueue(label: "com.batkill.logqueue")
    
    /// Buffer for pending log messages.
    private var buffer: [String] = []
    
    /// Maximum number of messages before auto-flush.
    private let maxBufferSize = 10
    
    /// Log file path.
    private let logPath = "/tmp/batkill.log"
    
    /// Whether the queue is currently flushing.
    private var isFlushing = false
    
    private init() {}
    
    deinit {
        flush() // Final flush on dealloc
    }
    
    /// Adds a message to the buffer. Triggers flush if buffer is full.
    func enqueue(_ message: String) {
        let timestamped = formatTimestamp(message)
        queue.async { [weak self] in
            guard let self = self else { return }
            self.buffer.append(timestamped)
            if self.buffer.count >= self.maxBufferSize {
                self.flushLocked()
            }
        }
    }
    
    /// Flushes all buffered messages to disk.
    func flush() {
        queue.async { [weak self] in
            self?.flushLocked()
        }
    }
    
    /// Internal flush (must be called on queue).
    private func flushLocked() {
        guard !isFlushing, !buffer.isEmpty else { return }
        isFlushing = true
        
        let messages = buffer
        buffer = []
        
        // Write batch to disk
        guard let data = messages.joined(separator: "\n").appending("\n").data(using: .utf8) else { return }
        
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
        }
        
        isFlushing = false
    }
    
    /// Formats a message with ISO-style timestamp.
    private func formatTimestamp(_ msg: String) -> String {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        return "[\(ts)] \(msg)"
    }
    
    /// Forces an immediate synchronous flush (for critical messages).
    func flushSync() {
        queue.sync { [weak self] in
            self?.flushLocked()
        }
    }
}

// MARK: - Debug Logging Control

/// Controls whether debug-level logging is enabled.
/// Debug logging can be toggled via rapid-click gesture on menu bar icon.
enum DebugLogger {
    /// Whether debug logging is currently enabled.
    static var isEnabled = false
    
    /// Toggles debug logging on/off.
    static func toggle() {
        isEnabled.toggle()
        let state = isEnabled ? "ENABLED" : "DISABLED"
        // Use direct write for toggle confirmation (bypasses queue)
        directLog("🔧 Debug logging \(state)")
    }
}

// MARK: - Public Logger Functions

/// Logs a message if debug logging is enabled.
/// Use this for detailed diagnostic messages that should not appear in production.
///
/// - Parameter msg: The debug message to record.
func debugLog(_ msg: String) {
    guard DebugLogger.isEnabled else { return }
    LogQueue.shared.enqueue(msg)
}

/// Logs a message (always, regardless of debug setting).
/// Use this for critical events that should always be recorded.
///
/// - Parameter msg: The log message to record.
func logger(_ msg: String) {
    LogQueue.shared.enqueue(msg)
}

/// Logs a critical message and forces immediate flush.
/// Use for crash-critical information that must be written immediately.
///
/// - Parameter msg: The critical log message to record.
func criticalLog(_ msg: String) {
    LogQueue.shared.enqueue(msg)
    LogQueue.shared.flushSync()
}

/// Direct synchronous write for toggle confirmations and critical startup messages.
/// Bypasses the queue for immediate visibility.
private func directLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/batkill.log") {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/batkill.log"), options: .atomic)
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
    
    /// Logs a message within this operation context.
    /// - Parameter message: The message to log.
    func log(_ message: String) {
        let prefix = parentName != nil ? "[\(parentName!)→\(name)]" : "[\(name)]"
        logger("\(prefix) \(message)")
    }
    
    /// Logs a debug message within this operation context.
    /// Only logs when debug logging is enabled.
    /// - Parameter message: The debug message to log.
    func debug(_ message: String) {
        let prefix = parentName != nil ? "[\(parentName!)→\(name)]" : "[\(name)]"
        debugLog("\(prefix) \(message)")
    }
    
    /// Marks the operation as complete and logs the result.
    /// - Parameters:
    ///   - success: Whether the operation succeeded.
    ///   - extra: Optional additional information.
    func complete(success: Bool, extra: String? = nil) {
        let duration = Date().timeIntervalSince(startTime)
        let status = success ? "✅" : "❌"
        let detail = extra != nil ? " (\(extra!))" : ""
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
        let fullParent = parentName != nil ? "\(parentName!)→\(name)" : name
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
