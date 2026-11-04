//  ProcessKillerTests.swift
//  BatKill Tests
//
//  Tests for pure logic in the kill/restore lifecycle (CHANGE-020 coverage).

import Foundation

final class ProcessKillerTests: TestCase {
    let name = "ProcessKillerTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("escapeAppleScriptText：转义反斜杠") {
            XCTAssertEqual(escapeAppleScriptText("a\\b"), "a\\\\b", "反斜杠应加倍")
        }

        runTest("escapeAppleScriptText：转义双引号") {
            XCTAssertEqual(escapeAppleScriptText("say \"hi\""), "say \\\"hi\\\"", "双引号应转义")
        }

        runTest("escapeAppleScriptText：转义换行") {
            XCTAssertEqual(escapeAppleScriptText("line1\nline2"), "line1\\nline2", "换行应转义")
        }

        runTest("escapeAppleScriptText：普通字符串保持不变") {
            XCTAssertEqual(escapeAppleScriptText("/Applications/App.app"), "/Applications/App.app", "无特殊字符不变")
        }

        runTest("escapeAppleScriptText：组合转义") {
            let out = escapeAppleScriptText("a\"b\\c\nd")
            XCTAssertEqual(out, "a\\\"b\\\\c\\nd", "反斜杠+引号+换行组合")
        }

        runTest("escapeAppleScriptText：空串") {
            XCTAssertEqual(escapeAppleScriptText(""), "", "空串不变")
        }

        runTest("appVisibilityScript：普通名 + visible false") {
            let script = appVisibilityScript(appName: "Calculator", visible: false)
            XCTAssertTrue(script.contains("first process whose name is \"Calculator\""), "应按显示名匹配")
            XCTAssertTrue(script.contains("to false"), "隐藏应为 false")
            XCTAssertTrue(script.hasPrefix("tell application \"System Events\" to set visible of"), "应为 System Events set visible")
        }

        runTest("appVisibilityScript：visible true") {
            let script = appVisibilityScript(appName: "Calculator", visible: true)
            XCTAssertTrue(script.contains("to true"), "恢复应为 true")
        }

        runTest("appVisibilityScript：注入防护（引号/反斜杠转义）") {
            // A crafted display name must not break out of the string literal.
            let script = appVisibilityScript(appName: "Foo\" ; tell app \"Bad\" to quit", visible: false)
            XCTAssertTrue(script.contains("Foo\\\""), "双引号应被转义，防止脚本注入")
            XCTAssertFalse(script.contains("\" ; tell app \""), "不应出现未转义的注入片段")
            XCTAssertFalse(script.contains("; tell app \"Bad\""), "注入命令不应原样进入脚本")
        }

        runTest("appVisibilityMatchName：显示名≠进程名时用进程名") {
            // WeCom case: list shows display name "wecom", but System Events
            // matches the process by executable name "企业微信".
            let app = AppItem(
                name: "wecom",
                bundleIdentifier: "com.tencent.WeWorkMac",
                path: "/Applications/企业微信.app",
                processName: "企业微信",
                isSelected: true,
                isSystemApp: false,
                category: .application,
                serviceLabel: nil
            )
            XCTAssertEqual(appVisibilityMatchName(app), "企业微信", "System Events 匹配应用可执行名（进程名），而非显示名")
            XCTAssertNotEqual(appVisibilityMatchName(app), app.name, "不应使用显示名（wecom），否则 System Events 匹配失败")
        }

        runTest("appVisibilityMatchName：显示名=进程名（Calculator）") {
            let app = AppItem(
                name: "Calculator",
                bundleIdentifier: "com.apple.calculator",
                path: "/System/Applications/Calculator.app",
                processName: "Calculator",
                isSelected: true,
                isSystemApp: true,
                category: .application,
                serviceLabel: nil
            )
            XCTAssertEqual(appVisibilityMatchName(app), "Calculator", "常规 app 进程名与显示名一致")
        }
    }
}
