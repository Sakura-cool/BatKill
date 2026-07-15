//  LoggerTests.swift
//  BatKill Tests
//
//  Tests for LogContext chain correlation and structured logging.

import Foundation

struct LoggerTests: TestCase {
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
    }
}