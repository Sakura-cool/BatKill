//  CLIFanWriterTests.swift
//  BatKill Tests
//
//  Tests for the privileged CLI argument whitelist (v0.1.6 FIX-002 /
//  CHANGE-019): fan index 0...15, speed 0...20000 finite, mode exactly 0|1.

import Foundation

final class CLIFanWriterTests: TestCase {
    let name = "CLIFanWriterTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("风扇索引白名单：0 与上界 15 通过") {
            XCTAssertTrue(isValidFanCLIIndex("0"))
            XCTAssertTrue(isValidFanCLIIndex("15"))
            XCTAssertTrue(isValidFanCLIIndex("7"))
        }

        runTest("风扇索引白名单：越界/非数字/溢出拒绝") {
            XCTAssertFalse(isValidFanCLIIndex("-1"), "负数索引必须拒绝")
            XCTAssertFalse(isValidFanCLIIndex("16"), "超出上界必须拒绝")
            XCTAssertFalse(isValidFanCLIIndex("abc"), "非数字必须拒绝")
            XCTAssertFalse(isValidFanCLIIndex(""), "空串必须拒绝")
            XCTAssertFalse(isValidFanCLIIndex("5.0"), "浮点文本必须拒绝")
            XCTAssertFalse(isValidFanCLIIndex("99999999999999999999"), "溢出整数必须拒绝")
        }

        runTest("转速白名单：0/上界/小数/科学计数通过") {
            XCTAssertTrue(isValidFanCLISpeed("0"))
            XCTAssertTrue(isValidFanCLISpeed("20000"))
            XCTAssertTrue(isValidFanCLISpeed("1500.5"))
            XCTAssertTrue(isValidFanCLISpeed("1e3"), "科学计数法（1000 RPM）应通过")
        }

        runTest("转速白名单：负数/超界/NaN/Infinity/非数字拒绝") {
            XCTAssertFalse(isValidFanCLISpeed("-1"), "负转速必须拒绝")
            XCTAssertFalse(isValidFanCLISpeed("20000.1"), "超出上界必须拒绝")
            XCTAssertFalse(isValidFanCLISpeed("nan"), "NaN 必须拒绝")
            XCTAssertFalse(isValidFanCLISpeed("inf"), "Infinity 必须拒绝")
            XCTAssertFalse(isValidFanCLISpeed("abc"), "非数字必须拒绝")
            XCTAssertFalse(isValidFanCLISpeed(""), "空串必须拒绝")
        }

        runTest("模式白名单：仅单字符 0/1 通过（与 sudoers [01] 匹配一致）") {
            XCTAssertTrue(isValidFanCLIMode("0"))
            XCTAssertTrue(isValidFanCLIMode("1"))
            XCTAssertFalse(isValidFanCLIMode("2"), "非 0/1 必须拒绝")
            XCTAssertFalse(isValidFanCLIMode("-1"))
            XCTAssertFalse(isValidFanCLIMode("00"), "多字符必须拒绝（sudoers [01] 只匹配单字符）")
            XCTAssertFalse(isValidFanCLIMode("01"))
            XCTAssertFalse(isValidFanCLIMode("true"))
            XCTAssertFalse(isValidFanCLIMode(""))
        }
    }
}
