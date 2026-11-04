//  SystemCoreProtectionTests.swift
//  BatKill Tests
//
//  Unit tests for SystemCoreProtection (v0.2.4 CHANGE-060):
//  the core-component predicate and the persisted-config cleanup migration.

import Foundation

final class SystemCoreProtectionTests: TestCase {
    let name = "SystemCoreProtectionTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        testIsCoreByBundleID()
        testIsCoreByProcessName()
        testIsCoreByCoreServicesPath()
        testIsCoreBySystemXPC()
        testIsNotCoreNormalApp()
        testCleanupRemovesCoreFromAllKeys()
    }

    // MARK: - Predicate Tests

    func testIsCoreByBundleID() {
        runTest("isCoreSystemComponent: Dock bundle ID") {
            XCTAssertTrue(SystemCoreProtection.isCoreSystemComponent(
                path: "/System/Library/CoreServices/Dock.app",
                bundleIdentifier: "com.apple.dock",
                processName: "Dock"), "com.apple.dock 应判定为核心组件")
        }
    }

    func testIsCoreByProcessName() {
        runTest("isCoreSystemComponent: WindowServer process name") {
            XCTAssertTrue(SystemCoreProtection.isCoreSystemComponent(
                path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
                bundleIdentifier: nil,
                processName: "WindowServer"), "WindowServer 进程名应判定为核心组件")
        }
    }

    func testIsCoreByCoreServicesPath() {
        runTest("isCoreSystemComponent: /System/Library/CoreServices/ path") {
            XCTAssertTrue(SystemCoreProtection.isCoreSystemComponent(
                path: "/System/Library/CoreServices/SystemUIServer.app",
                bundleIdentifier: nil,
                processName: "SystemUIServer"), "CoreServices 目录下的组件应判定为核心组件")
        }
    }

    func testIsCoreBySystemXPC() {
        runTest("isCoreSystemComponent: System XPC helper") {
            XCTAssertTrue(SystemCoreProtection.isCoreSystemComponent(
                path: "/System/Library/CoreServices/Dock.app/Contents/XPCServices/DockHelper.xpc",
                bundleIdentifier: nil,
                processName: "DockHelper"), "系统 XPC 辅助服务应判定为核心组件")
        }
    }

    func testIsNotCoreNormalApp() {
        runTest("isCoreSystemComponent: normal user app") {
            XCTAssertFalse(SystemCoreProtection.isCoreSystemComponent(
                path: "/Applications/TencentMeeting.app",
                bundleIdentifier: "com.tencent.meeting",
                processName: "TencentMeeting"), "普通用户应用不应判定为核心组件")
        }
    }

    // MARK: - Cleanup Tests

    func testCleanupRemovesCoreFromAllKeys() {
        runTest("cleanupPersistedConfig: 清除核心组件遗留配置") {
            let defaults = UserDefaults.standard

            // Save originals so the test restores them afterward.
            let origSuspended = defaults.stringArray(forKey: "suspendedPaths")
            let origSelected = defaults.stringArray(forKey: "selectedAppPaths")
            let origKilled = defaults.stringArray(forKey: "killedRestorePaths")
            let origStrategies = defaults.dictionary(forKey: "appSuspendStrategies")

            // Seed config with a core component (Dock) + a normal app (TencentMeeting).
            let corePath = "/System/Library/CoreServices/Dock.app"
            let normalPath = "/Applications/TencentMeeting.app"
            defaults.set([corePath, normalPath], forKey: "suspendedPaths")
            defaults.set([corePath, normalPath], forKey: "selectedAppPaths")
            defaults.set([corePath, normalPath], forKey: "killedRestorePaths")
            defaults.set([
                corePath: "suspend",
                normalPath: "force"
            ], forKey: "appSuspendStrategies")

            SystemCoreProtection.cleanupPersistedConfig()

            // Core component removed from every key; normal app retained.
            let suspended = defaults.stringArray(forKey: "suspendedPaths") ?? []
            let selected = defaults.stringArray(forKey: "selectedAppPaths") ?? []
            let killed = defaults.stringArray(forKey: "killedRestorePaths") ?? []
            let strategies = defaults.dictionary(forKey: "appSuspendStrategies") as? [String: String] ?? [:]

            XCTAssertFalse(suspended.contains(corePath), "核心组件应移出 suspendedPaths")
            XCTAssertFalse(selected.contains(corePath), "核心组件应移出 selectedAppPaths")
            XCTAssertFalse(killed.contains(corePath), "核心组件应移出 killedRestorePaths")
            XCTAssertNil(strategies[corePath], "核心组件应移出 appSuspendStrategies")

            XCTAssertTrue(suspended.contains(normalPath), "普通应用保留在 suspendedPaths")
            XCTAssertTrue(selected.contains(normalPath), "普通应用保留在 selectedAppPaths")
            XCTAssertTrue(killed.contains(normalPath), "普通应用保留在 killedRestorePaths")
            XCTAssertEqual(strategies[normalPath], "force", "普通应用策略保留")

            // Restore originals (nil removes the key).
            for (key, value) in [
                ("suspendedPaths", origSuspended as Any?),
                ("selectedAppPaths", origSelected as Any?),
                ("killedRestorePaths", origKilled as Any?),
                ("appSuspendStrategies", origStrategies as Any?)
            ] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
    }
}
