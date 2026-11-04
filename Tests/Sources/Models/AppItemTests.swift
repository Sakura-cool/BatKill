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
        testSuspendStrategyRawValues()
        testSuspendStrategyCaseIterable()
        testSuspendStrategyDefault()
        testSuspendStrategyCodingKeys()
        testSuspendStrategySupports()
        testSuspendStrategyAutoDefault()
        testSuspendStrategyRepaired()
        testSuspendStrategyExpired()
    }

    // MARK: - AppItem Codable Tests

    func testAppItemEncoding() {
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
            XCTAssertTrue(!data.isEmpty, "Encoded data should not be empty")
        }
    }

    func testAppItemDecoding() {
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

            let data = Data(json.utf8)
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

    func testAppItemRoundTrip() {
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

    func testAppItemCodingKeys() {
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
            let json = String(bytes: data, encoding: .utf8) ?? ""
            XCTAssertFalse(json.isEmpty, "编码结果应可解码为 UTF-8")

            // Transient fields should NOT be in JSON
            XCTAssertTrue(!json.contains("isRunning"), "isRunning should not be encoded")
            XCTAssertTrue(!json.contains("pid"), "pid should not be encoded")

            // Verify non-transient fields ARE present
            XCTAssertTrue(json.contains("name"), "name should be encoded")
            XCTAssertTrue(json.contains("path"), "path should be encoded")
        }
    }

    // MARK: - AppItem Equality Tests

    func testAppItemEquality() {
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

            let app2 = AppItem(
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

    func testAppItemID() {
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

    func testAppCategoryRawValues() {
        runTest("AppCategory raw values") {
            XCTAssertEqual(AppCategory.application.rawValue, "Application")
            XCTAssertEqual(AppCategory.service.rawValue, "Service")
            XCTAssertEqual(AppCategory.launchAgent.rawValue, "Launch Agent")
            XCTAssertEqual(AppCategory.custom.rawValue, "Custom")
        }
    }

    func testAppCategoryCaseIterable() {
        runTest("AppCategory case iterable") {
            let allCases = AppCategory.allCases
            XCTAssertEqual(allCases.count, 4, "Should have 4 categories")
            XCTAssertTrue(allCases.contains(.application))
            XCTAssertTrue(allCases.contains(.service))
            XCTAssertTrue(allCases.contains(.launchAgent))
            XCTAssertTrue(allCases.contains(.custom))
        }
    }

    // MARK: - SuspendStrategy Tests (REQ-017 / v0.2.4)

    func testSuspendStrategyRawValues() {
        runTest("SuspendStrategy raw values") {
            XCTAssertEqual(SuspendStrategy.suspend.rawValue, "suspend")
            XCTAssertEqual(SuspendStrategy.graceful.rawValue, "graceful")
            XCTAssertEqual(SuspendStrategy.force.rawValue, "force")
        }
    }

    func testSuspendStrategyCaseIterable() {
        runTest("SuspendStrategy case iterable") {
            let allCases = SuspendStrategy.allCases
            XCTAssertEqual(allCases.count, 3, "Should have 3 strategies")
            XCTAssertTrue(allCases.contains(.suspend))
            XCTAssertTrue(allCases.contains(.graceful))
            XCTAssertTrue(allCases.contains(.force))
        }
    }

    func testSuspendStrategyDefault() {
        runTest("AppItem default suspendStrategy is graceful") {
            let app = AppItem(
                name: "DefaultStrategy",
                bundleIdentifier: "com.default.strategy",
                path: "/Applications/DefaultStrategy.app",
                processName: "DefaultStrategy",
                isSelected: false,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            XCTAssertEqual(app.suspendStrategy, .graceful, "默认应为优雅退出")
            XCTAssertEqual(app.isSuspended, false, "默认未挂起")
        }
    }

    func testSuspendStrategyCodingKeys() {
        runTest("SuspendStrategy coded, isSuspended transient") {
            var app = AppItem(
                name: "StrategyCoding",
                bundleIdentifier: "com.strategy.coding",
                path: "/Applications/StrategyCoding.app",
                processName: "StrategyCoding",
                isSelected: false,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            app.suspendStrategy = .suspend
            app.isSuspended = true

            let encoder = JSONEncoder()
            let data = try encoder.encode(app)
            let json = String(bytes: data, encoding: .utf8) ?? ""

            // suspendStrategy IS persisted; isSuspended is transient
            XCTAssertTrue(json.contains("suspendStrategy"), "suspendStrategy 应被编码")
            XCTAssertTrue(json.contains("\"suspendStrategy\":\"suspend\""), "值应为 suspend")
            XCTAssertFalse(json.contains("isSuspended"), "isSuspended 不应被编码")
        }
    }

    // MARK: - Suspend Strategy Capability (CHANGE-061)

    func testSuspendStrategySupports() {
        runTest("supports: application supports all three") {
            let app = AppItem(
                name: "App", bundleIdentifier: "com.app", path: "/Applications/App.app",
                processName: "App", isSelected: false, isSystemApp: false,
                category: .application, serviceLabel: nil)
            XCTAssertTrue(app.supports(.suspend), ".application 支持挂起")
            XCTAssertTrue(app.supports(.graceful), ".application 支持优雅退出")
            XCTAssertTrue(app.supports(.force), ".application 支持强制退出")
            XCTAssertTrue(app.participatesInSuspendSequence)
        }

        runTest("supports: custom supports suspend only") {
            let app = AppItem(
                name: "Helper", bundleIdentifier: nil, path: "/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc",
                processName: "DockHelper", isSelected: false, isSystemApp: false,
                category: .custom, serviceLabel: nil)
            XCTAssertTrue(app.supports(.suspend), ".custom 支持挂起（唯一可恢复方式）")
            XCTAssertFalse(app.supports(.graceful), ".custom 不支持优雅退出（无启动机制）")
            XCTAssertFalse(app.supports(.force), ".custom 不支持强制退出（无启动机制）")
        }

        runTest("supports: launch agent / service not in sequence") {
            let agent = AppItem(
                name: "Agent", bundleIdentifier: nil, path: "/Library/LaunchAgents/a.plist",
                processName: "a", isSelected: false, isSystemApp: false,
                category: .launchAgent, serviceLabel: "a")
            XCTAssertFalse(agent.participatesInSuspendSequence, "launchAgent 不参与序列")
            XCTAssertFalse(agent.supports(.suspend))
            let service = AppItem(
                name: "Svc", bundleIdentifier: nil, path: "/opt/homebrew/opt/x",
                processName: "x", isSelected: false, isSystemApp: false,
                category: .service, serviceLabel: "x")
            XCTAssertFalse(service.participatesInSuspendSequence, "service 不参与序列")
            XCTAssertFalse(service.supports(.graceful))
        }
    }

    func testSuspendStrategyAutoDefault() {
        runTest("autoSuspendStrategy: application defaults to suspend") {
            let app = AppItem(
                name: "App", bundleIdentifier: "com.app", path: "/Applications/App.app",
                processName: "App", isSelected: false, isSystemApp: false,
                category: .application, serviceLabel: nil)
            XCTAssertEqual(app.autoSuspendStrategy, .suspend, "序列首选挂起")
        }

        runTest("autoSuspendStrategy: custom defaults to suspend") {
            let app = AppItem(
                name: "Helper", bundleIdentifier: nil, path: "/tmp/h.xpc",
                processName: "h", isSelected: false, isSystemApp: false,
                category: .custom, serviceLabel: nil)
            XCTAssertEqual(app.autoSuspendStrategy, .suspend, "custom 仅挂起可恢复 → 默认挂起")
        }
    }

    func testSuspendStrategyRepaired() {
        runTest("repairedStrategies: downgrades unsupported modes per sequence") {
            let custom = AppItem(
                name: "Helper", bundleIdentifier: nil, path: "/tmp/h.xpc",
                processName: "h", isSelected: false, isSystemApp: false,
                category: .custom, serviceLabel: nil)
            let app = AppItem(
                name: "App", bundleIdentifier: "com.app", path: "/Applications/App.app",
                processName: "App", isSelected: false, isSystemApp: false,
                category: .application, serviceLabel: nil)

            // custom stored as graceful/force (unsupported) -> repaired to suspend
            let repaired = AppItem.repairedStrategies(
                [custom.path: "graceful", app.path: "force"],
                for: [custom, app])
            XCTAssertEqual(repaired[custom.path], "suspend", "custom 不支持优雅 → 降级挂起")
            XCTAssertEqual(repaired[app.path], "force", ".app 支持强制 → 保留用户选择")
        }

        runTest("repairedStrategies: leaves supported & out-of-sequence entries") {
            let custom = AppItem(
                name: "Helper", bundleIdentifier: nil, path: "/tmp/h.xpc",
                processName: "h", isSelected: false, isSystemApp: false,
                category: .custom, serviceLabel: nil)
            let agent = AppItem(
                name: "Agent", bundleIdentifier: nil, path: "/Library/LaunchAgents/a.plist",
                processName: "a", isSelected: false, isSystemApp: false,
                category: .launchAgent, serviceLabel: "a")
            // custom=suspend (supported) stays; agent entry (out of sequence) untouched
            let repaired = AppItem.repairedStrategies(
                [custom.path: "suspend", agent.path: "force"],
                for: [custom, agent])
            XCTAssertEqual(repaired[custom.path], "suspend", "custom 挂起受支持 → 保留")
            XCTAssertEqual(repaired[agent.path], "force", "launchAgent 不参与序列 → 不动")
        }
    }

    func testSuspendStrategyExpired() {
        runTest("config expiry: 30+ days old is expired") {
            let now = Date()
            let old = now.addingTimeInterval(-31 * 24 * 3600)
            XCTAssertTrue(AppItem.isSuspendStrategyConfigExpired(lastSetAt: old, now: now, interval: 30 * 24 * 3600), "31 天前应过期")
        }
        runTest("config expiry: recent manual update not expired") {
            let now = Date()
            let recent = now.addingTimeInterval(-1 * 24 * 3600)
            XCTAssertFalse(AppItem.isSuspendStrategyConfigExpired(lastSetAt: recent, now: now, interval: 30 * 24 * 3600), "1 天前未过期")
        }
    }
}
