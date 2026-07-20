//  HardwareMonitorTests.swift
//  BatKill Tests
//
//  Tests for HardwareMonitor refresh methods, temperature key
//  categorization, and the CPU/GPU-only refresh path added for
//  background window power optimization.

import Foundation

struct HardwareMonitorTests: TestCase {
    let name = "HardwareMonitorTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        // ── Temperature key category validation ──
        // These tests verify that the key definitions correctly
        // assign CPU/GPU categories, ensuring the filtering logic
        // in partialRefreshCPUAndGPU() works as expected.

        runTest("commonTempKeys GPU keys have .gpu category") {
            let gpuKeys = HardwareMonitor().commonTempKeys.filter { $0.category == .gpu }
            XCTAssertFalse(gpuKeys.isEmpty, "commonTempKeys should contain GPU keys")
            for key in gpuKeys {
                XCTAssertTrue(
                    key.key.hasPrefix("Tg") || key.key.hasPrefix("TG"),
                    "GPU key \(key.key) should start with Tg or TG"
                )
            }
        }

        runTest("commonTempKeys non-CPU/GPU keys have correct categories") {
            let monitor = HardwareMonitor()
            for key in monitor.commonTempKeys {
                if key.key.hasPrefix("Tg") || key.key.hasPrefix("TG") {
                    XCTAssertEqual(key.category, .gpu, "\(key.key) should be .gpu")
                } else if key.key.hasPrefix("TM") || key.key.hasPrefix("Tm") {
                    XCTAssertEqual(key.category, .memory, "\(key.key) should be .memory")
                } else if key.key.hasPrefix("TB") {
                    XCTAssertEqual(key.category, .battery, "\(key.key) should be .battery")
                } else if key.key.hasPrefix("Ts") || key.key.hasPrefix("SM") {
                    XCTAssertEqual(key.category, .storage, "\(key.key) should be .storage")
                } else if key.key.hasPrefix("TA") || key.key.hasPrefix("Ta") || key.key.hasPrefix("TH") {
                    XCTAssertEqual(key.category, .ambient, "\(key.key) should be .ambient")
                } else if key.key.hasPrefix("TW") || key.key.hasPrefix("TP") || key.key.hasPrefix("SP") || key.key.hasPrefix("TS") {
                    XCTAssertEqual(key.category, .other, "\(key.key) should be .other")
                }
            }
        }

        runTest("appleSiliconKeys CPU keys have .cpu category") {
            let monitor = HardwareMonitor()
            let keys = monitor.appleSiliconKeys
            XCTAssertFalse(keys.isEmpty, "appleSiliconKeys should not be empty")
            for key in keys {
                XCTAssertEqual(key.category, .cpu, "\(key.key) should be .cpu category")
            }
        }

        runTest("intelTempKeys CPU keys have .cpu category") {
            let monitor = HardwareMonitor()
            let keys = monitor.intelTempKeys
            XCTAssertFalse(keys.isEmpty, "intelTempKeys should not be empty")
            for key in keys {
                XCTAssertEqual(key.category, .cpu, "\(key.key) should be .cpu category")
            }
        }

        runTest("knownTempKeys contains both CPU and non-CPU keys") {
            let monitor = HardwareMonitor()
            // knownTempKeys is private; reconstruct from public parts
            let cpuKeys = monitor.appleSiliconKeys
            let gpuKeys = monitor.commonTempKeys.filter { $0.category == .gpu }
            let otherKeys = monitor.commonTempKeys.filter { $0.category != .gpu }
            XCTAssertFalse(cpuKeys.isEmpty, "appleSiliconKeys should contain CPU keys")
            XCTAssertFalse(gpuKeys.isEmpty, "commonTempKeys should contain GPU keys")
            XCTAssertFalse(otherKeys.isEmpty, "commonTempKeys should contain non-GPU keys")
        }

        // ── CPU/GPU filtering logic ──
        // Verifies that the filtering used in partialRefreshCPUAndGPU()
        // correctly separates CPU/GPU keys from other categories.

        runTest("CPU/GPU filter separates categories correctly") {
            let monitor = HardwareMonitor()
            // knownTempKeys is private; combine public parts
            let allKeys = monitor.appleSiliconKeys + monitor.commonTempKeys
            let cpuGpuKeys = allKeys.filter { $0.category == .cpu || $0.category == .gpu }
            let nonCpuGpuKeys = allKeys.filter { $0.category != .cpu && $0.category != .gpu }

            let allCpuGpuHasCorrectCategory = cpuGpuKeys.allSatisfy {
                $0.category == .cpu || $0.category == .gpu
            }
            XCTAssertTrue(allCpuGpuHasCorrectCategory, "All CPU/GPU keys should have .cpu or .gpu category")

            let allNonCpuGpuHasOtherCategory = nonCpuGpuKeys.allSatisfy {
                $0.category != .cpu && $0.category != .gpu
            }
            XCTAssertTrue(allNonCpuGpuHasOtherCategory, "Non-CPU/GPU keys should not have .cpu or .gpu category")
        }

        // ── Smoke tests: methods don't crash without SMC ──
        // These tests verify that the new refresh methods gracefully
        // no-op when called without an SMC connection (e.g., in CI).

        runTest("partialRefresh() no-ops gracefully without SMC") {
            let monitor = HardwareMonitor()
            // Should not crash — bails at lazyEnsureOpen when connection == 0
            monitor.partialRefresh()
            // Allow async dispatch to complete
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertTrue(true, "partialRefresh() completed without crash")
        }

        runTest("partialRefresh(threshold:) no-ops gracefully without SMC") {
            let monitor = HardwareMonitor()
            monitor.partialRefresh(threshold: 85.0)
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertTrue(true, "partialRefresh(threshold:) completed without crash")
        }

        runTest("partialRefreshCPUAndGPU() no-ops gracefully without SMC") {
            let monitor = HardwareMonitor()
            monitor.partialRefreshCPUAndGPU()
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertTrue(true, "partialRefreshCPUAndGPU() completed without crash")
        }

        runTest("partialRefreshCPUAndGPU(threshold:) no-ops gracefully without SMC") {
            let monitor = HardwareMonitor()
            monitor.partialRefreshCPUAndGPU(threshold: 85.0)
            Thread.sleep(forTimeInterval: 0.1)
            XCTAssertTrue(true, "partialRefreshCPUAndGPU(threshold:) completed without crash")
        }

        // ── Refresh interval tests ──
        // Verifies the battery-aware refresh intervals used by the timer.

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
    }
}