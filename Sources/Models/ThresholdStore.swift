//  ThresholdStore.swift
//  BatKill
//
//  Manages the CPU temperature threshold for automatic fan safety intervention.
//
//  When the maximum CPU temperature exceeds this threshold, the app triggers
//  a thermal throttle event: it locks the fan to automatic mode (if admin-authorized)
//  and displays a warning to the user. This prevents hardware damage from sustained
//  high temperatures when the user has manually set aggressive fan speeds.
//
//  The threshold is persisted in UserDefaults under the key "fanTemperatureThreshold".
//  Valid range: 60-120 degrees Celsius. Default: 98 degrees Celsius.
//
//  Extracted from: Models.swift

import Foundation
import Combine

/// Observable store for the CPU temperature threshold setting.
///
/// The threshold determines when the app considers the CPU to be overheating.
/// Upon exceeding this value, `HardwareMonitor.checkThreshold()` fires the
/// thermal throttle callback, which triggers automatic fan mode restoration
/// (if admin authorization is available) and displays a warning indicator.
///
/// ### UserDefaults Persistence
/// Stored under key `"fanTemperatureThreshold"`. A stored value of `0` (which
/// is impossible in practice) is treated as uninitialized and falls back to the
/// default of 98 degrees Celsius.
///
/// ### Valid Range
/// The UI slider constrains this value to 60-120 degrees Celsius.
/// Values outside this range should not be set programmatically.
final class TemperatureThresholdStore: ObservableObject {
    /// The current CPU temperature threshold in degrees Celsius.
    /// Automatically persisted to UserDefaults on every change via `didSet`.
    @Published var threshold: Double {
        didSet { UserDefaults.standard.set(threshold, forKey: key) }
    }

    /// UserDefaults key for the threshold value.
    private let key = "fanTemperatureThreshold"

    /// Fallback default threshold (98 degrees Celsius).
    /// Chosen as a safe default that allows sustained workloads but catches genuine overheating.
    private let defaultValue: Double = 98

    /// Initializes the store by loading the persisted threshold from UserDefaults.
    /// Falls back to `defaultValue` if no value is stored or if the stored value is 0.
    init() {
        let stored = UserDefaults.standard.double(forKey: key)
        self.threshold = stored > 0 ? stored : 98
    }
}
