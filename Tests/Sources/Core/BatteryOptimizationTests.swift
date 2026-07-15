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
            XCTAssertEqual(interval, 4.0, "x86_64 refresh on AC should be 4s")
            #else
            XCTAssertEqual(interval, 2.0, "arm64 refresh on AC should be 2s")
            #endif
        }

        runTest("hardwareRefreshInterval on battery") {
            let interval = hardwareRefreshInterval(onBattery: true)
            #if arch(x86_64)
            XCTAssertEqual(interval, 6.0, "x86_64 refresh on battery should be 6s")
            #else
            XCTAssertEqual(interval, 3.0, "arm64 refresh on battery should be 3s")
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
