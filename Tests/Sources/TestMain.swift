//  TestMain.swift
//  BatKill Tests
//
//  Main entry point for the test executable.
//  Registers all test cases and runs them.

import Foundation

// MARK: - Test Main Entry Point

@main
struct TestMain {
    static func main() {
        // Register all test cases
        TestRunner.register("AppItemTests") { AppItemTests() }
        TestRunner.register("FanPresetTests") { FanPresetTests() }
        TestRunner.register("ThresholdStoreTests") { ThresholdStoreTests() }
        TestRunner.register("HardwareModelsTests") { HardwareModelsTests() }
        TestRunner.register("LocalizationTests") { LocalizationTests() }
        TestRunner.register("ExtensionsTests") { ExtensionsTests() }
        TestRunner.register("BatteryOptimizationTests") { BatteryOptimizationTests() }
        
        // Run all tests
        TestRunner.runAll()
        
        // Exit with appropriate code
        if TestResults.shared.allPassed {
            exit(0)
        } else {
            exit(1)
        }
    }
}
