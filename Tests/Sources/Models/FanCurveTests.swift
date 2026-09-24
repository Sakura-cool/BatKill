//  FanCurveTests.swift
//  BatKill Tests
//
//  Unit tests for FanCurve model, ManualSubMode, CurveTarget, and
//  FanCurveStore. Covers the curve mapping boundaries, monotonicity
//  constraint, Codable round-trip, and UserDefaults persistence.

import Foundation

final class FanCurveTests: TestCase {
    let name = "FanCurveTests"

    func setUp() {
        UserDefaults.standard.removeObject(forKey: "fanManualSubModes")
        UserDefaults.standard.removeObject(forKey: "fanCurves")
        UserDefaults.standard.removeObject(forKey: FanCurve.thresholdDefaultsKey)
    }

    func tearDown() {
        UserDefaults.standard.removeObject(forKey: "fanManualSubModes")
        UserDefaults.standard.removeObject(forKey: "fanCurves")
        UserDefaults.standard.removeObject(forKey: FanCurve.thresholdDefaultsKey)
    }

    func run() {
        testCurveDefaultInit()
        testMaxStepIndex()
        testStepTemperature()
        testTargetSpeedBelowZero()
        testTargetSpeedAtExactStep()
        testTargetSpeedInterpolation()
        testTargetSpeedAtThreshold()
        testTargetSpeedAboveThreshold()
        testMonotonicCheck()
        testClamped()
        testCurveCodableRoundTrip()
        testStorePersistence()
        testStoreSubModeFallback()
    }

    // MARK: - Curve Construction

    func testCurveDefaultInit() {
        runTest("FanCurve default init") {
            let curve = FanCurve(threshold: 100, baseSpeed: 800)
            XCTAssertEqual(curve.threshold, 100)
            XCTAssertEqual(Int(curve.stepSpeeds[0] ?? -1), 800)
            XCTAssertEqual(Int(curve.stepSpeeds[10] ?? -1), 800, "max step = threshold/10 seeded")
        }
    }

    // MARK: - Step Index & Temperature

    func testMaxStepIndex() {
        runTest("FanCurve maxStepIndex") {
            XCTAssertEqual(FanCurve.maxStepIndex(for: 98), 10, "non-multiple threshold floors to ceil/10")
            XCTAssertEqual(FanCurve.maxStepIndex(for: 100), 10)
            XCTAssertEqual(FanCurve.maxStepIndex(for: 120), 12)
            XCTAssertEqual(FanCurve.maxStepIndex(for: 0), 0)
        }
    }

    func testStepTemperature() {
        runTest("FanCurve step temperatures") {
            XCTAssertEqual(FanCurve.temperature(atStep: 0, threshold: 98), 0)
            XCTAssertEqual(FanCurve.temperature(atStep: 5, threshold: 98), 50)
            XCTAssertEqual(FanCurve.temperature(atStep: 10, threshold: 98), 98, "last step is the threshold itself")
            XCTAssertEqual(FanCurve.temperature(atStep: 12, threshold: 120), 120)
        }
    }

    // MARK: - Target Speed Mapping

    func testTargetSpeedBelowZero() {
        runTest("targetSpeed below 0 uses first step") {
            var curve = FanCurve(threshold: 60, baseSpeed: 500)
            curve.stepSpeeds = [0: 500, 1: 800, 2: 1200, 3: 1500, 4: 1800, 5: 2000, 6: 2200]
            XCTAssertEqual(curve.targetSpeed(for: -5), .speed(500))
        }
    }

    func testTargetSpeedAtExactStep() {
        runTest("targetSpeed at exact 10 °C step") {
            var curve = FanCurve(threshold: 60, baseSpeed: 500)
            curve.stepSpeeds = [0: 500, 1: 800, 2: 1200, 3: 1500, 4: 1800, 5: 2000, 6: 2200]
            XCTAssertEqual(curve.targetSpeed(for: 20), .speed(1200))
            XCTAssertEqual(curve.targetSpeed(for: 40), .speed(1800))
        }
    }

    func testTargetSpeedInterpolation() {
        runTest("targetSpeed linear interpolation") {
            var curve = FanCurve(threshold: 100, baseSpeed: 500)
            // 10°C → 800, 20°C → 1200: at 15°C expect 1000
            curve.stepSpeeds = [0: 500, 1: 800, 2: 1200, 3: 1600,
                                4: 2000, 5: 2400, 6: 2800, 7: 3200,
                                8: 3600, 9: 4000, 10: 4400]
            guard case .speed(let v) = curve.targetSpeed(for: 15) else {
                XCTAssertFalse(true, "expected .speed for 15°C")
                return
            }
            XCTAssertEqualWithAccuracy(v, 1000, accuracy: 0.01)
        }
    }

    func testTargetSpeedAtThreshold() {
        runTest("targetSpeed at threshold uses last step") {
            var curve = FanCurve(threshold: 98, baseSpeed: 500)
            for k in 0...10 { curve.stepSpeeds[k] = 500 + Double(k) * 100 }
            // Last step temperature is 98; index 10 speed = 1500
            if case .speed(let v) = curve.targetSpeed(for: 98) {
                XCTAssertEqualWithAccuracy(v, 1500, accuracy: 0.01)
            } else {
                XCTAssertFalse(true, "expected .speed at threshold")
            }
        }
    }

    func testTargetSpeedAboveThreshold() {
        runTest("targetSpeed above threshold returns systemControl") {
            var curve = FanCurve(threshold: 98, baseSpeed: 500)
            for k in 0...10 { curve.stepSpeeds[k] = 500 + Double(k) * 100 }
            XCTAssertEqual(curve.targetSpeed(for: 99), .systemControl)
            XCTAssertEqual(curve.targetSpeed(for: 150), .systemControl)
        }
    }

    // MARK: - Monotonicity

    func testMonotonicCheck() {
        runTest("isMonotonic detects regressions") {
            var curve = FanCurve(threshold: 60, baseSpeed: 500)
            curve.stepSpeeds = [0: 500, 1: 800, 2: 1200, 3: 1500, 4: 1500, 5: 2000, 6: 2200]
            XCTAssertTrue(curve.isMonotonic)

            curve.stepSpeeds[3] = 900   // breaks monotonicity (1500 → 900)
            XCTAssertFalse(curve.isMonotonic)
        }
    }

    func testClamped() {
        runTest("clamped restores monotonicity") {
            var curve = FanCurve(threshold: 60, baseSpeed: 500)
            curve.stepSpeeds = [0: 500, 1: 800, 2: 1200, 3: 600, 4: 1800, 5: 2000, 6: 2200]
            let clamped = curve.clamped()
            XCTAssertTrue(clamped.isMonotonic)
            XCTAssertEqual(Int(clamped.stepSpeeds[3] ?? -1), 1200, "raised to previous max")
        }
    }

    // MARK: - Codable

    func testCurveCodableRoundTrip() {
        runTest("FanCurve Codable round-trip") {
            var curve = FanCurve(threshold: 100, baseSpeed: 600)
            curve.stepSpeeds[2] = 1400
            let data = try JSONEncoder().encode(curve)
            let decoded = try JSONDecoder().decode(FanCurve.self, from: data)
            XCTAssertEqual(decoded.threshold, 100)
            XCTAssertEqual(Int(decoded.stepSpeeds[2] ?? -1), 1400)
        }
    }

    // MARK: - Store

    func testStorePersistence() {
        runTest("FanCurveStore persistence round-trip") {
            let store = FanCurveStore()
            store.setSubMode(.curve, for: 0)
            var curve = FanCurve(threshold: 100, baseSpeed: 700)
            curve.stepSpeeds[1] = 1200
            store.setCurve(curve, for: 0)

            let reloaded = FanCurveStore()
            XCTAssertEqual(reloaded.subMode(for: 0), .curve)
            XCTAssertEqual(Int(reloaded.curve(for: 0, currentSpeed: 700).stepSpeeds[1] ?? -1), 1200)
        }
    }

    func testStoreSubModeFallback() {
        runTest("FanCurveStore subMode falls back to fixed") {
            let store = FanCurveStore()
            XCTAssertEqual(store.subMode(for: 3), .fixed)
        }
    }
}
