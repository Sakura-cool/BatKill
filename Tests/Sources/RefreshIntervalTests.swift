//  RefreshIntervalTests.swift
//  BatKill Tests
//
//  Unit tests for the v0.2.3 full-cycle refresh interval maths in
//  `Sources/Views/RefreshInterval.swift`: tick counting, per-tick interval
//  conversion, the minimum tick floor, and the battery-aware fallback.

import Foundation

final class RefreshIntervalTests: TestCase {
    let name = "RefreshIntervalTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        testRefreshTicksPerCycleDividesEvenly()
        testRefreshTicksPerCycleCeils()
        testRefreshTicksPerCycleGuards()
        testRefreshTickIntervalDividesCycle()
        testRefreshTickIntervalMinimumFloor()
        testRefreshTickIntervalFallsBackWithoutKeys()
        testRefreshTickIntervalFallsBackOnNonPositiveCycle()
        testRefreshTickIntervalMonotonic()
        testRefreshTickIntervalDefaultFallbackMatches()
    }

    // MARK: - refreshTicksPerCycle

    func testRefreshTicksPerCycleDividesEvenly() {
        runTest("refreshTicksPerCycle divides evenly") {
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 10, batchSize: 2), 5)
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 20, batchSize: 1), 20)
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 1, batchSize: 2), 1)
        }
    }

    func testRefreshTicksPerCycleCeils() {
        runTest("refreshTicksPerCycle rounds up partial batches") {
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 11, batchSize: 2), 6)
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 9, batchSize: 4), 3)
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 18, batchSize: 2), 9)
        }
    }

    func testRefreshTicksPerCycleGuards() {
        runTest("refreshTicksPerCycle guards against non-positive inputs") {
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 0, batchSize: 2), 1)
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: 10, batchSize: 0), 1)
            XCTAssertEqual(refreshTicksPerCycle(sensorKeyCount: -5, batchSize: 2), 1)
        }
    }

    // MARK: - refreshTickInterval

    func testRefreshTickIntervalDividesCycle() {
        runTest("refreshTickInterval divides the cycle by the tick count") {
            XCTAssertEqualWithAccuracy(
                refreshTickInterval(cycleSeconds: 6, sensorKeyCount: 20, batchSize: 2, onBattery: false),
                0.6,
                accuracy: 0.0001)
            XCTAssertEqualWithAccuracy(
                refreshTickInterval(cycleSeconds: 9, sensorKeyCount: 18, batchSize: 2, onBattery: true),
                1.0,
                accuracy: 0.0001)
        }
    }

    func testRefreshTickIntervalMinimumFloor() {
        runTest("refreshTickInterval never drops below minimumRefreshTick") {
            // 40 keys / batch 1 = 40 ticks; 1 s / 40 would be 0.025 s.
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: 1, sensorKeyCount: 40, batchSize: 1, onBattery: false),
                minimumRefreshTick)
        }
    }

    func testRefreshTickIntervalFallsBackWithoutKeys() {
        runTest("refreshTickInterval falls back when the key count is unknown") {
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: 3, sensorKeyCount: 0, batchSize: 2, onBattery: true),
                hardwareRefreshInterval(onBattery: true))
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: 3, sensorKeyCount: -1, batchSize: 2, onBattery: false),
                hardwareRefreshInterval(onBattery: false))
        }
    }

    func testRefreshTickIntervalFallsBackOnNonPositiveCycle() {
        runTest("refreshTickInterval falls back for a non-positive cycle") {
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: 0, sensorKeyCount: 20, batchSize: 2, onBattery: false),
                hardwareRefreshInterval(onBattery: false))
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: -2, sensorKeyCount: 20, batchSize: 2, onBattery: true),
                hardwareRefreshInterval(onBattery: true))
        }
    }

    func testRefreshTickIntervalMonotonic() {
        runTest("refreshTickInterval grows with the requested cycle") {
            var previous = 0.0
            for cycle in stride(from: 1.0, through: 9.0, by: 1.0) {
                let tick = refreshTickInterval(cycleSeconds: cycle, sensorKeyCount: 18, batchSize: 2, onBattery: false)
                XCTAssertTrue(tick >= previous, "Tick must be monotonic, got \(tick) after \(previous)")
                previous = tick
            }
        }
    }

    func testRefreshTickIntervalDefaultFallbackMatches() {
        runTest("fallback returns the battery-aware program default") {
            let acDefault = hardwareRefreshInterval(onBattery: false)
            let batteryDefault = hardwareRefreshInterval(onBattery: true)
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: 6, sensorKeyCount: 0, batchSize: 2, onBattery: false),
                acDefault)
            XCTAssertEqual(
                refreshTickInterval(cycleSeconds: 6, sensorKeyCount: 0, batchSize: 2, onBattery: true),
                batteryDefault)
        }
    }
}
