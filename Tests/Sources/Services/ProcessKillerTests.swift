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
    }
}
