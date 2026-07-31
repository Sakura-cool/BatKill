//  BatteryOptimizationTests.swift
//  BatKill Tests
//
//  Tests for battery-aware polling interval selection in
//  BatteryMonitor and TemperatureView.
//
//  These intervals are architecture-specific (arm64 vs x86_64).
//  Each architecture tests its own compiled-in values.

import Foundation

final class BatteryOptimizationTests: TestCase {
    let name = "BatteryOptimizationTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("batteryPollInterval on AC power") {
            let interval = batteryPollInterval(onBattery: false)
            XCTAssertEqual(interval, 5.0, "BatteryMonitor AC poll interval should be 5s")
        }

        runTest("batteryPollInterval on battery") {
            let interval = batteryPollInterval(onBattery: true)
            XCTAssertEqual(interval, 15.0, "BatteryMonitor battery poll interval should be 15s")
        }

        runTest("batteryPollInterval battery longer than AC") {
            let ac = batteryPollInterval(onBattery: false)
            let battery = batteryPollInterval(onBattery: true)
            XCTAssertTrue(battery > ac, "battery poll interval must be ≥ AC interval for power saving")
        }
    }
}
