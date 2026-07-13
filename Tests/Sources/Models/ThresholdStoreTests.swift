//  ThresholdStoreTests.swift
//  BatKill Tests
//
//  Unit tests for TemperatureThresholdStore.
//  Tests threshold persistence, default values, and boundary conditions.

import Foundation

final class ThresholdStoreTests: TestCase {
    let name = "ThresholdStoreTests"
    
    private let testKey = "test_fanTemperatureThreshold"
    
    func setUp() {
        // Clear test key before each test
        UserDefaults.standard.removeObject(forKey: testKey)
    }
    
    func tearDown() {
        // Clean up after tests
        UserDefaults.standard.removeObject(forKey: testKey)
    }
    
    func run() {
        testDefaultThreshold()
        testThresholdPersistence()
        testThresholdChange()
        testThresholdBoundary()
        testThresholdZeroDefault()
        testThresholdNegativeDefault()
    }
    
    // MARK: - ThresholdStore Tests
    
    private func testDefaultThreshold() {
        runTest("TemperatureThresholdStore default value") {
            // Clear any existing value
            UserDefaults.standard.removeObject(forKey: "fanTemperatureThreshold")
            
            let store = TemperatureThresholdStore()
            
            XCTAssertEqual(store.threshold, 98.0, "Default threshold should be 98°C")
        }
    }
    
    private func testThresholdPersistence() {
        runTest("TemperatureThresholdStore persistence") {
            // Clear existing value
            UserDefaults.standard.removeObject(forKey: "fanTemperatureThreshold")
            
            let store1 = TemperatureThresholdStore()
            store1.threshold = 75.0
            
            // Create new instance - should load persisted value
            let store2 = TemperatureThresholdStore()
            
            XCTAssertEqual(store2.threshold, 75.0, "Should persist threshold value")
        }
    }
    
    private func testThresholdChange() {
        runTest("TemperatureThresholdStore change notification") {
            let store = TemperatureThresholdStore()
            var changeDetected = false
            
            // Use Combine to detect changes
            let cancellable = store.$threshold.sink { _ in
                changeDetected = true
            }
            
            store.threshold = 85.0
            
            XCTAssertTrue(changeDetected, "Changing threshold should trigger publisher")
            XCTAssertEqual(store.threshold, 85.0)
            
            cancellable.cancel()
        }
    }
    
    private func testThresholdBoundary() {
        runTest("TemperatureThresholdStore boundary values") {
            let store = TemperatureThresholdStore()
            
            // Test minimum boundary
            store.threshold = 60.0
            XCTAssertEqual(store.threshold, 60.0)
            
            // Test maximum boundary
            store.threshold = 120.0
            XCTAssertEqual(store.threshold, 120.0)
            
            // Test middle value
            store.threshold = 90.0
            XCTAssertEqual(store.threshold, 90.0)
        }
    }
    
    private func testThresholdZeroDefault() {
        runTest("TemperatureThresholdStore zero stored value uses default") {
            // Store 0 (which is treated as uninitialized)
            UserDefaults.standard.set(0.0, forKey: "fanTemperatureThreshold")
            
            let store = TemperatureThresholdStore()
            
            XCTAssertEqual(store.threshold, 98.0, "Zero stored value should fallback to default 98°C")
        }
    }
    
    private func testThresholdNegativeDefault() {
        runTest("TemperatureThresholdStore negative stored value uses default") {
            // Store negative (invalid)
            UserDefaults.standard.set(-10.0, forKey: "fanTemperatureThreshold")
            
            let store = TemperatureThresholdStore()
            
            // Note: The implementation checks `stored > 0`, so negative should fallback
            XCTAssertEqual(store.threshold, 98.0, "Negative stored value should fallback to default 98°C")
        }
    }
}
