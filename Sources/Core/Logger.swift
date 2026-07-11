//  Logger.swift
//  BatKill
//
//  Shared file-based logger for the BatKill application.
//  All log output is appended to /tmp/batkill.log with ISO-style timestamps.
//  This function is used throughout the codebase for debugging and diagnostics.
//
//  Usage:  logger("Some event happened")
//  View:   tail -f /tmp/batkill.log
//
//  Extracted from: BatteryMonitor.swift

import Foundation

/// Simple file-based logger that appends timestamped messages to `/tmp/batkill.log`.
///
/// If the log file already exists, the message is appended via `FileHandle`.
/// If it does not exist, a new file is created atomically.
///
/// - Parameter msg: The log message to record.
func logger(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    if let data = "[\(ts)] \(msg)\n".data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/batkill.log") {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: "/tmp/batkill.log"), options: .atomic)
        }
    }
}
