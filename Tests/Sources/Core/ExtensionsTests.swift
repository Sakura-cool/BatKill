//  ExtensionsTests.swift
//  BatKill Tests
//
//  Unit tests for Swift extensions.
//  Tests Binding.onChange and Notification.Name extensions.

import Foundation
import SwiftUI

final class ExtensionsTests: TestCase {
    let name = "ExtensionsTests"
    
    func setUp() {}
    func tearDown() {}
    
    func run() {
        testBindingOnChange()
        testBindingOnChangeMultipleSets()
        testBindingOnChangeWithState()
        testNotificationNames()
    }
    
    // MARK: - Binding.onChange Tests
    
    private func testBindingOnChange() {
        runTest("Binding.onChange fires handler on set") {
            var handlerCalled = false
            var receivedValue: Int?
            var backingValue = 0
            
            let binding = Binding(
                get: { backingValue },
                set: { backingValue = $0 }
            )
            
            let onChangeBinding = binding.onChange { newValue in
                handlerCalled = true
                receivedValue = newValue
            }
            
            // Set the value
            onChangeBinding.wrappedValue = 42
            
            XCTAssertTrue(handlerCalled, "Handler should be called")
            XCTAssertEqual(receivedValue, 42, "Handler should receive new value")
            XCTAssertEqual(backingValue, 42, "Original binding should be updated")
        }
    }
    
    private func testBindingOnChangeMultipleSets() {
        runTest("Binding.onChange fires handler on multiple sets") {
            var callCount = 0
            var lastValue: Int?
            
            @State var value = 0
            let binding = Binding(
                get: { value },
                set: { value = $0 }
            )
            
            let onChangeBinding = binding.onChange { newValue in
                callCount += 1
                lastValue = newValue
            }
            
            onChangeBinding.wrappedValue = 1
            onChangeBinding.wrappedValue = 2
            onChangeBinding.wrappedValue = 3
            
            XCTAssertEqual(callCount, 3, "Handler should be called 3 times")
            XCTAssertEqual(lastValue, 3, "Last value should be 3")
        }
    }
    
    private func testBindingOnChangeWithState() {
        runTest("Binding.onChange works with @State-like pattern") {
            var capturedValues: [String] = []
            
            var state = "initial"
            let binding = Binding(
                get: { state },
                set: { state = $0 }
            )
            
            let onChangeBinding = binding.onChange { newValue in
                capturedValues.append(newValue)
            }
            
            onChangeBinding.wrappedValue = "first"
            onChangeBinding.wrappedValue = "second"
            
            XCTAssertEqual(capturedValues, ["first", "second"])
            XCTAssertEqual(state, "second", "State should reflect last set value")
        }
    }
    
    // MARK: - Notification.Name Tests
    
    private func testNotificationNames() {
        runTest("Notification.Name extensions exist") {
            // Just verify the notification names are defined and accessible
            let showSettings = Notification.Name.showSettings
            let showTemperature = Notification.Name.showTemperature
            
            XCTAssertEqual(showSettings.rawValue, "showSettings")
            XCTAssertEqual(showTemperature.rawValue, "showTemperature")
        }
    }
}
