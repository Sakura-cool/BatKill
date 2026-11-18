//  SystemLoadReaderTests.swift
//  BatKill Tests
//
//  Tests for the v0.2.6 SystemLoadReader (mach host_statistics CPU usage).

import Foundation

final class SystemLoadReaderTests: TestCase {
    let name = "SystemLoadReaderTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("SystemLoadReader：首次调用返回 0（基线）") {
            let reader = SystemLoadReader()
            XCTAssertEqual(reader.currentUsage(), 0, "首次调用仅记录基线，无增量")
        }

        runTest("SystemLoadReader：后续调用返回 [0,100] 占用") {
            let reader = SystemLoadReader()
            _ = reader.currentUsage() // baseline
            let usage = reader.currentUsage()
            XCTAssertTrue(usage >= 0 && usage <= 100, "占用应在 0-100 区间，实际 \(usage)")
        }
    }
}
