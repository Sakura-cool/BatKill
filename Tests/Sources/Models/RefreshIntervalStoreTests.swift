//  RefreshIntervalStoreTests.swift
//  BatKill Tests
//
//  Unit tests for TemperatureRefreshIntervalStore (v0.2.3 CHANGE-047).
//  Covers the persisted default, range clamping, invalid stored values, and
//  change notification.

import Foundation
import Combine

final class RefreshIntervalStoreTests: TestCase {
    let name = "RefreshIntervalStoreTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        testDefaultInterval()
        testIntervalPersistence()
        testSetClampsHigh()
        testSetClampsLow()
        testSetSameValueNoRepublish()
        testStoredZeroFallsBack()
        testStoredNegativeFallsBack()
        testStoredOutOfRangeFallsBack()
        testClampStatic()
        testChangeNotification()
    }

    // MARK: - RefreshIntervalStore Tests

    func testDefaultInterval() {
        runTest("TemperatureRefreshIntervalStore default value") {
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()

            XCTAssertEqual(store.seconds, 6, "Default interval should be 6 seconds")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testIntervalPersistence() {
        runTest("TemperatureRefreshIntervalStore persistence") {
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")

            let store1 = TemperatureRefreshIntervalStore()
            store1.set(seconds: 3)

            let store2 = TemperatureRefreshIntervalStore()

            XCTAssertEqual(store2.seconds, 3, "Should persist the interval value")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testSetClampsHigh() {
        runTest("TemperatureRefreshIntervalStore clamps values above 9") {
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()
            store.set(seconds: 12)
            XCTAssertEqual(store.seconds, 9, "Values above 9 must clamp to 9")
            store.set(seconds: 1000)
            XCTAssertEqual(store.seconds, 9, "Large values must clamp to 9")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testSetClampsLow() {
        runTest("TemperatureRefreshIntervalStore clamps values below 1") {
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()
            store.set(seconds: 0)
            XCTAssertEqual(store.seconds, 1, "Zero must clamp to 1")
            store.set(seconds: -5)
            XCTAssertEqual(store.seconds, 1, "Negative values must clamp to 1")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testSetSameValueNoRepublish() {
        runTest("TemperatureRefreshIntervalStore does not re-publish identical values") {
            UserDefaults.standard.set(4, forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()
            var changeCount = 0
            // dropFirst() skips the initial value emission, which is not a change
            let cancellable = store.$seconds.dropFirst().sink { _ in changeCount += 1 }

            store.set(seconds: 4)
            XCTAssertEqual(changeCount, 0, "Setting the same value must not publish")
            store.set(seconds: 7)
            XCTAssertEqual(changeCount, 1, "A real change must publish exactly once")
            XCTAssertEqual(store.seconds, 7)

            cancellable.cancel()
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testStoredZeroFallsBack() {
        runTest("TemperatureRefreshIntervalStore zero stored value uses default") {
            // 0 is what UserDefaults returns for a missing key and is invalid.
            UserDefaults.standard.set(0, forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()

            XCTAssertEqual(store.seconds, 6, "Zero stored value should fallback to default 6")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testStoredNegativeFallsBack() {
        runTest("TemperatureRefreshIntervalStore negative stored value uses default") {
            UserDefaults.standard.set(-3, forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()

            XCTAssertEqual(store.seconds, 6, "Negative stored value should fallback to default 6")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testStoredOutOfRangeFallsBack() {
        runTest("TemperatureRefreshIntervalStore out-of-range stored value uses default") {
            UserDefaults.standard.set(42, forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()

            XCTAssertEqual(store.seconds, 6, "Out-of-range stored value should fallback to default 6")
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }

    func testClampStatic() {
        runTest("TemperatureRefreshIntervalStore.clamp bounds") {
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(0), 1)
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(-99), 1)
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(1), 1)
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(5), 5)
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(9), 9)
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(10), 9)
            XCTAssertEqual(TemperatureRefreshIntervalStore.clamp(999), 9)
        }
    }

    func testChangeNotification() {
        runTest("TemperatureRefreshIntervalStore change notification") {
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")

            let store = TemperatureRefreshIntervalStore()
            var lastValue: Int?
            // dropFirst() skips the initial value emission, which is not a change
            let cancellable = store.$seconds.dropFirst().sink { value in lastValue = value }

            store.set(seconds: 8)

            XCTAssertEqual(lastValue, 8, "Changing the interval should publish the new value")
            XCTAssertEqual(store.seconds, 8)

            cancellable.cancel()
            UserDefaults.standard.removeObject(forKey: "temperatureRefreshSeconds")
        }
    }
}
