//  RefreshIntervalStore.swift
//  BatKill
//
//  Manages the temperature-window refresh interval setting (v0.2.3): how many
//  seconds one FULL sweep of all temperature sensors should take while the
//  hardware monitor window is open (integer, 1-9).
//
//  Persistence is unconditional (UserDefaults, survives window close and app
//  restart) so the value is remembered; the value is only *consumed* by the
//  temperature window's own refresh timer, so closing the window restores the
//  program's default refresh cadence and no other refresh path is affected.
//
//  Valid range: 1-9 seconds. Default: 6 seconds.
//
//  UserDefaults key: "temperatureRefreshSeconds"

import Foundation
import Combine

/// Observable store for the temperature-window refresh interval setting.
///
/// The stored value is the target duration of ONE full sensor sweep in
/// seconds (integer, 1-9). `TemperatureView` converts it into a per-tick
/// interval (see `refreshTickInterval`) when it builds its refresh timer.
///
/// ### UserDefaults Persistence
/// Stored under key `"temperatureRefreshSeconds"`. `UserDefaults.integer`
/// returns 0 for a missing key, which is outside the valid range and therefore
/// falls back to the default of 6 seconds.
///
/// ### Scope
/// The value only takes effect while the temperature window is open: it is
/// read exclusively by that window's timer, which is invalidated on close.
final class TemperatureRefreshIntervalStore: ObservableObject {
    /// Target seconds for one full sensor sweep. Persisted on every change.
    @Published var seconds: Int {
        didSet { UserDefaults.standard.set(seconds, forKey: key) }
    }

    /// UserDefaults key for the setting.
    private let key = "temperatureRefreshSeconds"

    /// Minimum allowed full-sweep duration in seconds.
    static let minValue = 1

    /// Maximum allowed full-sweep duration in seconds.
    static let maxValue = 9

    /// Fallback default (6 seconds). The previous fixed implementation swept
    /// all sensors in roughly 8-13 s on AC and 16-26 s on battery; 6 seconds
    /// is the middle ground between responsiveness and SMC read pressure.
    static let defaultValue = 6

    /// Initializes the store from the persisted value, falling back to
    /// `defaultValue` when nothing is stored or the stored value is invalid.
    init() {
        let stored = UserDefaults.standard.integer(forKey: key)
        self.seconds = stored >= Self.minValue && stored <= Self.maxValue ? stored : Self.defaultValue
    }

    /// Applies a candidate value, clamped into 1-9, and persists it.
    ///
    /// No-op when the clamped value equals the current one, so repeated
    /// keypresses of the same digit do not re-publish or re-persist.
    func set(seconds newValue: Int) {
        let clamped = Self.clamp(newValue)
        guard clamped != seconds else { return }
        seconds = clamped
    }

    /// Clamps any candidate value into the valid 1-9 range.
    static func clamp(_ value: Int) -> Int {
        min(maxValue, max(minValue, value))
    }
}
