//  FanControllerTests.swift
//  BatKill Tests
//
//  Tests for the CHANGE-019 sudo fan-write channel guards:
//  invalid requests and the blocked latch are rejected synchronously
//  WITHOUT spawning a privileged process (no sudo, no SMC write).

import Foundation

final class FanControllerTests: TestCase {
    let name = "FanControllerTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("非法转速（NaN/负数）同步拒绝，不进入提权通道") {
            let monitor = HardwareMonitor()
            var result = false
            var called = false

            monitor.setFanSpeedWithAdmin(fanIndex: 0, speed: .nan) {
                result = $0
                called = true
            }
            XCTAssertTrue(called, "NaN 转速必须同步回调")
            XCTAssertFalse(result, "NaN 转速必须拒绝")

            called = false
            monitor.setFanSpeedWithAdmin(fanIndex: 0, speed: -1) {
                result = $0
                called = true
            }
            XCTAssertTrue(called, "负数转速必须同步回调")
            XCTAssertFalse(result, "负数转速必须拒绝")
        }

        runTest("非法风扇索引同步拒绝（setFanSpeedWithAdmin）") {
            let monitor = HardwareMonitor()
            var result = false
            var called = false
            // Index 99 远超任何真实风扇数：无论本机 SMC 是否可用都必须拒绝，
            // 且不触发提权写入。
            monitor.setFanSpeedWithAdmin(fanIndex: 99, speed: 100) {
                result = $0
                called = true
            }
            XCTAssertTrue(called, "非法风扇索引必须同步回调")
            XCTAssertFalse(result, "非法风扇索引的写入必须拒绝")
        }

        runTest("非法风扇索引同步拒绝（setFanModeWithAdmin）") {
            let monitor = HardwareMonitor()
            var result = false
            var called = false
            monitor.setFanModeWithAdmin(fanIndex: 99, auto: false) {
                result = $0
                called = true
            }
            XCTAssertTrue(called, "非法风扇索引必须同步回调")
            XCTAssertFalse(result, "非法风扇索引的模式切换必须拒绝")
        }

        runTest("提权通道锁存后 runWithAdmin 同步拒绝，不拉起 sudo") {
            let monitor = HardwareMonitor()
            // Save latch state and force blocked (restored even on failure).
            let wasBlocked = HardwareMonitor.adminExecBlocked
            let wasBlockedAt = HardwareMonitor.adminExecBlockedAt
            HardwareMonitor.adminExecBlocked = true
            HardwareMonitor.adminExecBlockedAt = Date().timeIntervalSinceReferenceDate
            defer {
                HardwareMonitor.adminExecBlocked = wasBlocked
                HardwareMonitor.adminExecBlockedAt = wasBlockedAt
            }

            var result = false
            var called = false
            monitor.runWithAdmin(args: ["--set-fan", "0", "100"]) {
                result = $0
                called = true
            }
            XCTAssertTrue(called, "锁存期间必须同步回调")
            XCTAssertFalse(result, "锁存期间写入必须拒绝（不得拉起 sudo）")
        }

        runTest("retryAdminExec() 清除锁存，允许显式重试") {
            HardwareMonitor.adminExecBlocked = true
            HardwareMonitor.adminExecBlockedAt = Date().timeIntervalSinceReferenceDate
            HardwareMonitor.retryAdminExec()
            XCTAssertFalse(HardwareMonitor.adminExecBlocked, "显式重试应清除锁存")
            XCTAssertEqual(HardwareMonitor.adminExecBlockedAt, 0, "锁存时间应清零")
        }
    }
}
