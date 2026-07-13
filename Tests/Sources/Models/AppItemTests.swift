//  AppItemTests.swift
//  BatKill Tests
//
//  Unit tests for AppItem model and AppCategory enum.
//  Tests encoding/decoding, equality, and coding key behavior.

import Foundation

final class AppItemTests: TestCase {
    let name = "AppItemTests"
    
    func setUp() {}
    func tearDown() {}
    
    func run() {
        testAppItemEncoding()
        testAppItemDecoding()
        testAppItemRoundTrip()
        testAppItemCodingKeys()
        testAppItemEquality()
        testAppItemID()
        testAppCategoryRawValues()
        testAppCategoryCaseIterable()
    }
    
    // MARK: - AppItem Codable Tests
    
    private func testAppItemEncoding() {
        runTest("AppItem encoding") {
            let app = AppItem(
                name: "TestApp",
                bundleIdentifier: "com.test.app",
                path: "/Applications/TestApp.app",
                processName: "TestApp",
                isSelected: true,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            
            let encoder = JSONEncoder()
            let data = try encoder.encode(app)
            
            XCTAssertNotNil(data, "Encoded data should not be nil")
            XCTAssertTrue(data.count > 0, "Encoded data should not be empty")
        }
    }
    
    private func testAppItemDecoding() {
        runTest("AppItem decoding") {
            let json = """
            {
                "name": "DecodedApp",
                "bundleIdentifier": "com.decoded.app",
                "path": "/Applications/DecodedApp.app",
                "processName": "DecodedApp",
                "isSelected": false,
                "isSystemApp": true,
                "category": "Service",
                "serviceLabel": "com.test.service"
            }
            """
            
            let data = json.data(using: .utf8)!
            let decoder = JSONDecoder()
            let app = try decoder.decode(AppItem.self, from: data)
            
            XCTAssertEqual(app.name, "DecodedApp")
            XCTAssertEqual(app.bundleIdentifier, "com.decoded.app")
            XCTAssertEqual(app.path, "/Applications/DecodedApp.app")
            XCTAssertEqual(app.processName, "DecodedApp")
            XCTAssertEqual(app.isSelected, false)
            XCTAssertEqual(app.isSystemApp, true)
            XCTAssertEqual(app.category, .service)
            XCTAssertEqual(app.serviceLabel, "com.test.service")
        }
    }
    
    private func testAppItemRoundTrip() {
        runTest("AppItem encode/decode round trip") {
            let original = AppItem(
                name: "RoundTripApp",
                bundleIdentifier: "com.roundtrip.app",
                path: "/Applications/RoundTripApp.app",
                processName: "RoundTripApp",
                isSelected: true,
                isSystemApp: true,
                category: .launchAgent,
                serviceLabel: "com.roundtrip.agent"
            )
            
            let encoder = JSONEncoder()
            let data = try encoder.encode(original)
            
            let decoder = JSONDecoder()
            let decoded = try decoder.decode(AppItem.self, from: data)
            
            XCTAssertEqual(decoded.name, original.name)
            XCTAssertEqual(decoded.bundleIdentifier, original.bundleIdentifier)
            XCTAssertEqual(decoded.path, original.path)
            XCTAssertEqual(decoded.processName, original.processName)
            XCTAssertEqual(decoded.isSelected, original.isSelected)
            XCTAssertEqual(decoded.isSystemApp, original.isSystemApp)
            XCTAssertEqual(decoded.category, original.category)
            XCTAssertEqual(decoded.serviceLabel, original.serviceLabel)
        }
    }
    
    private func testAppItemCodingKeys() {
        runTest("AppItem coding keys exclude transient fields") {
            let app = AppItem(
                name: "TransientTest",
                bundleIdentifier: "com.transient.test",
                path: "/Applications/TransientTest.app",
                processName: "TransientTest",
                isSelected: false,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            
            // Set transient fields
            var mutableApp = app
            mutableApp.isRunning = true
            mutableApp.pid = 12345
            
            let encoder = JSONEncoder()
            let data = try encoder.encode(mutableApp)
            let json = String(data: data, encoding: .utf8)!
            
            // Transient fields should NOT be in JSON
            XCTAssertTrue(!json.contains("isRunning"), "isRunning should not be encoded")
            XCTAssertTrue(!json.contains("pid"), "pid should not be encoded")
            
            // Verify non-transient fields ARE present
            XCTAssertTrue(json.contains("name"), "name should be encoded")
            XCTAssertTrue(json.contains("path"), "path should be encoded")
        }
    }
    
    // MARK: - AppItem Equality Tests
    
    private func testAppItemEquality() {
        runTest("AppItem equality by path (id)") {
            let app1 = AppItem(
                name: "App1",
                bundleIdentifier: "com.test.app",
                path: "/Applications/Test.app",
                processName: "Test",
                isSelected: false,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            
            var app2 = AppItem(
                name: "App2 Different Name", // Different name
                bundleIdentifier: "com.test.app",
                path: "/Applications/Test.app", // Same path
                processName: "Test",
                isSelected: true, // Different selection
                isSystemApp: true, // Different system app flag
                category: .application,
                serviceLabel: nil
            )
            
            // AppItem doesn't conform to Equatable directly, but id (path) should be the same
            XCTAssertEqual(app1.id, app2.id, "Same path should produce same id")
        }
    }
    
    private func testAppItemID() {
        runTest("AppItem id is path") {
            let testPath = "/Applications/MyApp.app"
            let app = AppItem(
                name: "MyApp",
                bundleIdentifier: "com.my.app",
                path: testPath,
                processName: "MyApp",
                isSelected: false,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            
            XCTAssertEqual(app.id, testPath, "AppItem id should be the path")
        }
    }
    
    // MARK: - AppCategory Tests
    
    private func testAppCategoryRawValues() {
        runTest("AppCategory raw values") {
            XCTAssertEqual(AppCategory.application.rawValue, "Application")
            XCTAssertEqual(AppCategory.service.rawValue, "Service")
            XCTAssertEqual(AppCategory.launchAgent.rawValue, "Launch Agent")
            XCTAssertEqual(AppCategory.custom.rawValue, "Custom")
        }
    }
    
    private func testAppCategoryCaseIterable() {
        runTest("AppCategory case iterable") {
            let allCases = AppCategory.allCases
            XCTAssertEqual(allCases.count, 4, "Should have 4 categories")
            XCTAssertTrue(allCases.contains(.application))
            XCTAssertTrue(allCases.contains(.service))
            XCTAssertTrue(allCases.contains(.launchAgent))
            XCTAssertTrue(allCases.contains(.custom))
        }
    }
}
