//  SystemLoadReader.swift
//  BatKill
//
//  Reads the system-wide CPU usage percentage via the mach host_statistics
//  API (HOST_CPU_LOAD_INFO), sampling the user/system/idle/nice tick counters
//  across two consecutive calls. The delta between samples yields the average
//  CPU utilization since the previous sample (0-100).
//
//  Used by ProcessKiller's sequential restore scheduler to decide the wait
//  interval before launching the next app: a busy system gets a longer
//  interval so the restore does not compound load spikes.
//
//  Zero external dependencies (mach API), mirroring BatteryMonitor's
//  system-level read pattern. First call returns 0 (baseline only).

import Darwin
import Foundation

/// Reads the system CPU usage percentage (0-100) using mach host statistics.
///
/// - Note: The first call only records the baseline tick counters and returns
///   0 (no delta available yet). Each subsequent call returns the average
///   utilization since the previous call. Counter wraparound is handled with
///   modular subtraction (`&-`).
final class SystemLoadReader {
    /// Last sampled tick counters (user, system, idle, nice).
    private var lastTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?

    /// Cached host port send right. `mach_host_self()` returns a new send
    /// right per call that the caller must release; caching it once avoids
    /// a per-sample acquisition/leak (the host port is system-wide and the
    /// reader lives for the app's lifetime).
    private lazy var hostPort: mach_port_t = mach_host_self()

    deinit {
        if hasAcquiredHostPort {
            mach_port_deallocate(mach_task_self_, hostPort)
        }
    }
    private var hasAcquiredHostPort = false

    /// Returns the average CPU usage percentage since the previous sample.
    /// Returns 0 on the first call (baseline) or when the read fails.
    func currentUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        if !hasAcquiredHostPort { hasAcquiredHostPort = true }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }

        let t = info.cpu_ticks
        if let last = lastTicks {
            // Modular subtraction handles counter wraparound; the sums are
            // widened to Int so a long inter-sample gap (or many cores) cannot
            // overflow UInt32 and trap.
            let dUser = Int(t.0 &- last.0)
            let dSys = Int(t.1 &- last.1)
            let dIdle = Int(t.2 &- last.2)
            let dNice = Int(t.3 &- last.3)
            let total = dUser + dSys + dIdle + dNice
            lastTicks = (t.0, t.1, t.2, t.3)
            guard total > 0 else { return 0 }
            return Double(dUser + dSys + dNice) / Double(total) * 100
        } else {
            lastTicks = (t.0, t.1, t.2, t.3)
            return 0
        }
    }
}
