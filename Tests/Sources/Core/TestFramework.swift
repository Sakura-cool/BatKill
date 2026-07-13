//  TestFramework.swift
//  BatKill Tests
//
//  Lightweight test framework for BatKill unit tests.
//  Provides basic assertion functions and test case registration
//  without requiring XCTest (which needs Xcode).
//
//  Usage:
//    TestRunner.runAll()
//    // or
//    TestRunner.runTest("testName")

import Foundation

// MARK: - Test Results

/// Tracks test execution results and provides summary reporting.
final class TestResults {
    static let shared = TestResults()
    
    private var passed: Int = 0
    private var failed: Int = 0
    private var errors: [(test: String, message: String)] = []
    
    func recordPass() { passed += 1 }
    func recordFail(test: String, message: String) {
        failed += 1
        errors.append((test: test, message: message))
    }
    
    func summary() -> String {
        let total = passed + failed
        var result = "\n═══════════════════════════════════════════\n"
        result += "  TEST RESULTS: \(passed)/\(total) passed"
        if failed > 0 { result += ", \(failed) FAILED" }
        result += "\n═══════════════════════════════════════════\n"
        
        for error in errors {
            result += "  ❌ \(error.test): \(error.message)\n"
        }
        
        if failed == 0 && passed > 0 {
            result += "  ✅ All tests passed!\n"
        }
        
        result += "═══════════════════════════════════════════\n"
        return result
    }
    
    var allPassed: Bool { failed == 0 }
}

// MARK: - Assertion Functions

/// Assert that two values are equal.
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if lhs == rhs {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected \(lhs) to equal \(rhs)" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

/// Assert that two values are not equal.
func XCTAssertNotEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if lhs != rhs {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected \(lhs) to not equal \(rhs)" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

/// Assert that a condition is true.
func XCTAssertTrue(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if condition {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected condition to be true" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

/// Assert that a condition is false.
func XCTAssertFalse(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
    if !condition {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected condition to be false" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

/// Assert that a value is nil.
func XCTAssertNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value == nil {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected value to be nil, got \(value!)" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

/// Assert that a value is not nil.
func XCTAssertNotNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value != nil {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected value to not be nil" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

/// Assert that a value is within a tolerance range (for floating point comparisons).
func XCTAssertEqualWithAccuracy(_ lhs: Double, _ rhs: Double, accuracy: Double, _ message: String = "", file: String = #file, line: Int = #line) {
    if abs(lhs - rhs) <= accuracy {
        TestResults.shared.recordPass()
    } else {
        let testName = "\(file):\(line)"
        let msg = message.isEmpty ? "Expected \(lhs) to equal \(rhs) ± \(accuracy)" : message
        TestResults.shared.recordFail(test: testName, message: msg)
        print("  ❌ FAIL: \(msg)")
    }
}

// MARK: - Test Case Protocol

/// A test case that can be executed by the test runner.
protocol TestCase {
    var name: String { get }
    func setUp()
    func tearDown()
    func run()
}

// MARK: - Test Runner

/// Executes registered test cases and reports results.
enum TestRunner {
    private static var testCases: [String: () -> TestCase] = [:]
    
    /// Register a test case class.
    static func register(_ name: String, _ factory: @escaping () -> TestCase) {
        testCases[name] = factory
    }
    
    /// Run all registered tests.
    static func runAll() {
        print("\n🧪 Running BatKill Unit Tests...\n")
        
        for (name, factory) in testCases.sorted(by: { $0.key < $1.key }) {
            print("── \(name) ──")
            let testCase = factory()
            testCase.setUp()
            testCase.run()
            testCase.tearDown()
            print("")
        }
        
        print(TestResults.shared.summary())
    }
    
    /// Run a specific test case by name.
    static func runTest(_ name: String) {
        guard let factory = testCases[name] else {
            print("❌ Test '\(name)' not found")
            return
        }
        
        print("\n🧪 Running: \(name)\n")
        let testCase = factory()
        testCase.setUp()
        testCase.run()
        testCase.tearDown()
        
        print(TestResults.shared.summary())
    }
}

// MARK: - Test Helper

/// Helper function for running a block with error handling.
func runTest(_ name: String, _ block: () throws -> Void) {
    print("  ▸ \(name)")
    do {
        try block()
    } catch {
        print("  ❌ ERROR: \(error)")
        TestResults.shared.recordFail(test: name, message: "Threw error: \(error)")
    }
}
