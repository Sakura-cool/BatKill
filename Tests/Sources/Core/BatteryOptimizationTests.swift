//  BatteryOptimizationTests.swift
//  BatKill Tests
//
//  Tests for battery-aware polling interval selection in
//  BatteryMonitor and TemperatureView.
//
//  These intervals are architecture-specific (arm64 vs x86_64).
//  Each architecture tests its own compiled-in values.

import Foundation

struct BatteryOptimizationTests: TestCase {
    let name = "BatteryOptimizationTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("hardwareRefreshInterval on AC power") {
            let interval = hardwareRefreshInterval(onBattery: false)
            #if arch(x86_64)
            XCTAssertEqual(interval, 1.2, "x86_64 per-tick interval on AC should be 1.2s")
            #else
            XCTAssertEqual(interval, 1.0, "arm64 per-tick interval on AC should be 1.0s")
            #endif
        }

        runTest("hardwareRefreshInterval on battery") {
            let interval = hardwareRefreshInterval(onBattery: true)
            #if arch(x86_64)
            XCTAssertEqual(interval, 2.5, "x86_64 per-tick interval on battery should be 2.5s")
            #else
            XCTAssertEqual(interval, 2.0, "arm64 per-tick interval on battery should be 2.0s")
            #endif
        }

        runTest("hardwareRefreshInterval battery longer than AC") {
            let ac = hardwareRefreshInterval(onBattery: false)
            let battery = hardwareRefreshInterval(onBattery: true)
            XCTAssertTrue(battery > ac, "battery interval must be ≥ AC interval for power saving")
        }

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
