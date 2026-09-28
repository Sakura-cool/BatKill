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

/// Debounce delay (0.1s) before a slider/curve edit applies its write, so
/// rapid drags coalesce into one SMC write (CHANGE-018).
let fanApplyDebounceNs: UInt64 = 100_000_000
