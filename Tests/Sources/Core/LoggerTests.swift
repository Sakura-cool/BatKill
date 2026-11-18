//  LoggerTests.swift
//  BatKill Tests
//
//  Tests for LogContext chain correlation and structured logging.

import Foundation

final class LoggerTests: TestCase {
    let name = "LoggerTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("LogContext root has no parent") {
            let ctx = LogContext(name: "testOp")
            XCTAssertEqual(ctx.name, "testOp", "name should match")
            XCTAssertNil(ctx.parentName, "root context should have nil parent")
        }

        runTest("LogContext child preserves parent name") {
            let parent = LogContext(name: "parent")
            let child = parent.child("child")
            XCTAssertEqual(child.name, "child", "child name should match")
            XCTAssertEqual(child.parentName, "parent", "child parentName should be parent's name")
        }

        runTest("LogContext multi-level chain") {
            let root = LogContext(name: "root")
            let child = root.child("middle")
            let grandchild = child.child("leaf")

            XCTAssertEqual(grandchild.name, "leaf")
            XCTAssertEqual(grandchild.parentName, "root→middle",
                "grandchild's parentName should preserve the full chain: root→middle")
        }

        runTest("LogContext id is unique per instance") {
            let ctx1 = LogContext(name: "a")
            let ctx2 = LogContext(name: "b")
            XCTAssertNotEqual(ctx1.id, ctx2.id, "each context should have a unique id")
        }

        runTest("LogContext id is 8 characters") {
            let ctx = LogContext(name: "test")
            XCTAssertEqual(ctx.id.count, 8, "id should be 8 chars (UUID prefix)")
        }

        runTest("LogContext startTime is recent") {
            let ctx = LogContext(name: "test")
            let now = Date()
            let diff = now.timeIntervalSince(ctx.startTime)
            XCTAssertTrue(diff < 1.0, "startTime should be within 1 second of creation")
        }

        runTest("LogContext child with explicit parent") {
            let ctx = LogContext(name: "child", parent: "explicitParent")
            XCTAssertEqual(ctx.name, "child")
            XCTAssertEqual(ctx.parentName, "explicitParent")
        }

        runTest("LogContext deep chain preserves all levels") {
            let a = LogContext(name: "a")
            let b = a.child("b")
            let c = b.child("c")
            let d = c.child("d")

            XCTAssertEqual(d.parentName, "a→b→c",
                "4-level chain should preserve a→b→c as parent of d")
            XCTAssertEqual(d.name, "d")
        }

        // MARK: - Log rotation / retention / levels (v0.2.6)

        runTest("日志轮转：达到阈值应轮转，未达不轮转") {
            XCTAssertTrue(LogRotation.shouldRotate(currentSize: LogRotation.maxLogSize),
                "恰好达到阈值应轮转")
            XCTAssertTrue(LogRotation.shouldRotate(currentSize: LogRotation.maxLogSize + 1))
            XCTAssertFalse(LogRotation.shouldRotate(currentSize: LogRotation.maxLogSize - 1),
                "未达阈值不应轮转")
            XCTAssertFalse(LogRotation.shouldRotate(currentSize: 0))
        }

        runTest("日志压缩：gzip 非空输入产生合法 gzip（魔数 1F 8B）且更小") {
            let payload = Data(repeating: 0x41, count: 8192) // "AAAA..." 高可压缩
            guard let gz = LogRotation.gzipCompress(payload) else {
                XCTAssertTrue(false, "gzipCompress 应成功")
                return
            }
            XCTAssertGreaterThan(gz.count, 2, "gzip 输出应非空")
            XCTAssertEqual(gz[0], 0x1F, "gzip 魔数第 1 字节应为 0x1F")
            XCTAssertEqual(gz[1], 0x8B, "gzip 魔数第 2 字节应为 0x8B")
            XCTAssertLessThan(gz.count, payload.count, "高可压缩数据应显著变小")
        }

        runTest("日志压缩：空输入返回 nil（不崩溃）") {
            XCTAssertNil(LogRotation.gzipCompress(Data()), "空输入应返回 nil")
        }

        runTest("日志级别：严重级单调递增 + 文案") {
            XCTAssertLessThan(LogLevel.debug, LogLevel.info)
            XCTAssertLessThan(LogLevel.info, LogLevel.warning)
            XCTAssertLessThan(LogLevel.warning, LogLevel.error)
            XCTAssertEqual(LogLevel.debug.description, "DEBUG")
            XCTAssertEqual(LogLevel.info.description, "INFO")
            XCTAssertEqual(LogLevel.warning.description, "WARN")
            XCTAssertEqual(LogLevel.error.description, "ERROR")
        }
    }
}
