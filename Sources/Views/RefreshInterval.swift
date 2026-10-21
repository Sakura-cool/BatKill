import Foundation

// MARK: - Battery-Aware Refresh Interval

/// Returns the hardware sensor refresh interval based on the current
/// architecture and power source. Polls less frequently on battery
/// to reduce SMC/IOKit overhead.
///
/// Per-tick interval for staggered SMC reads. Each tick reads ONE sensor
/// key. With ~15-20 keys, a full refresh cycle takes interval × keyCount
/// seconds (~6-8s on AC, ~10-14s on battery).
///
/// |              | Apple Silicon | Intel x86_64 |
/// |--------------|--------------|--------------|
/// | AC Power     |  1.0s        |  1.2s        |
/// | Battery      |  2.0s        |  2.5s        |
func hardwareRefreshInterval(onBattery: Bool) -> TimeInterval {
    #if arch(x86_64)
    return onBattery ? 2.5 : 1.2
    #else
    return onBattery ? 2.0 : 1.0
    #endif
}

func batteryPollInterval(onBattery: Bool) -> TimeInterval {
    onBattery ? 15.0 : 5.0
}

// MARK: - User-Configured Full-Cycle Refresh (v0.2.3)

/// Minimum per-tick interval (s). Bounds the SMC read rate when the user picks
/// a very short full-sweep duration with many sensor keys; overlapping ticks
/// are additionally dropped by `HardwareMonitor.isRefreshing`.
let minimumRefreshTick: TimeInterval = 0.1

/// Number of timer ticks needed for ONE full sweep of `sensorKeyCount`
/// temperature keys when each tick reads `batchSize` keys.
///
/// Returns 1 for non-positive inputs so callers always divide by a
/// non-zero tick count.
func refreshTicksPerCycle(sensorKeyCount: Int, batchSize: Int) -> Int {
    guard sensorKeyCount > 0, batchSize > 0 else { return 1 }
    return Int((Double(sensorKeyCount) + Double(batchSize) - 1) / Double(batchSize))
}

/// Per-tick interval (s) that makes ONE full sensor sweep take about
/// `cycleSeconds` (the user's "full refresh seconds" setting).
///
/// Falls back to the battery-aware program default when the sensor key count
/// is not known yet (before the first SMC scan) or the cycle is non-positive.
func refreshTickInterval(cycleSeconds: Double, sensorKeyCount: Int, batchSize: Int, onBattery: Bool) -> TimeInterval {
    guard cycleSeconds > 0, sensorKeyCount > 0 else { return hardwareRefreshInterval(onBattery: onBattery) }
    let ticks = refreshTicksPerCycle(sensorKeyCount: sensorKeyCount, batchSize: batchSize)
    return max(minimumRefreshTick, cycleSeconds / Double(ticks))
}

/// Debounce delay (0.1s) before a slider/curve edit applies its write, so
/// rapid drags coalesce into one SMC write (CHANGE-018).
let fanApplyDebounceNs: UInt64 = 100_000_000
