//  PowerLoadReader.swift
//  BatKill
//
//  Reads the Mac's real-time power profile via IOKit's AppleSmartBattery
//  registry entry: instantaneous whole-system power draw, the connected
//  charger's rated wattage, battery health (max capacity vs design), and
//  current charge level. Used by the sequential restore scheduler to pace
//  restore launches by the power-curve SLOPE (dW/dt) so a low-power charger
//  cannot be overwhelmed into a battery-protection shutdown (v0.2.6 AC-620).
//
//  All values are read on demand from the registry (no polling timer), the
//  same event-driven style as BatteryMonitor — the reader is instantiated per
//  restore sequence and sampled once per launch step, adding zero idle cost.
//
//  Zero external dependencies (IOKit), mirroring SystemLoadReader.

import Foundation
import IOKit

/// Reads the power profile needed for slope-aware restore pacing.
/// All getters return nil when the AppleSmartBattery service or a property
/// is unavailable, so callers can degrade gracefully to CPU-only pacing.
final class PowerLoadReader {
    /// Cached AppleSmartBattery IOKit service. Released on deinit.
    private var service: io_service_t = 0

    init() {
        service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 {
            IOObjectRelease(service)
        }
    }

    private var isOpen: Bool { service != 0 }

    /// Reads a numeric property from a sub-dictionary of the battery entry.
    private func number(_ key: String, in dict: [String: Any]?) -> Double? {
        guard let dict, let num = dict[key] as? NSNumber else { return nil }
        return num.doubleValue
    }

    private func dict(_ key: String) -> [String: Any]? {
        guard isOpen,
              let cf = IORegistryEntryCreateCFProperty(
                  service, key as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() else { return nil }
        return cf as? [String: Any]
    }

    /// Instantaneous whole-system power draw in watts.
    func currentPowerWatts() -> Double? {
        guard let telemetry = dict("PowerTelemetryData") else { return nil }
        // `SystemPowerIn` is in milliwatts.
        guard let mW = number("SystemPowerIn", in: telemetry) else { return nil }
        return mW / 1000
    }

    /// The connected charger's rated wattage (e.g. 65). nil on battery power.
    func chargerWatts() -> Double? {
        guard let adapter = dict("AdapterDetails") else { return nil }
        return number("Watts", in: adapter)
    }

    /// Battery health 0-1: FullChargeCapacity / DesignCapacity.
    func batteryHealth() -> Double? {
        guard let battery = dict("BatteryData") else { return nil }
        guard let full = number("AppleRawMaxCapacity", in: battery),
              let design = number("DesignCapacity", in: battery),
              design > 0 else { return nil }
        return full / design
    }

    /// Battery charge level 0-1 (CurrentCapacity is already a percentage 0-100).
    func batteryLevel() -> Double? {
        guard let battery = dict("BatteryData") else { return nil }
        guard let current = number("AppleRawCurrentCapacity", in: battery),
              let max = number("AppleRawMaxCapacity", in: battery),
              max > 0 else { return nil }
        return current / max
    }
}
