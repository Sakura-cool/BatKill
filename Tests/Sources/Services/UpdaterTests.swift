//  UpdaterTests.swift
//  BatKill Tests
//
//  Tests for the version-comparison logic (CHANGE-020 test coverage).

import Foundation

final class UpdaterTests: TestCase {
    let name = "UpdaterTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("remote 主版本更高 → true") {
            XCTAssertTrue(compareVersions("0.1.7", "0.1.9"), "1.9 > 1.7")
            XCTAssertTrue(compareVersions("0.1.9", "0.2.0"), "2.0 > 1.9")
            XCTAssertTrue(compareVersions("1.0.0", "2.0.0"), "2 > 1")
        }

        runTest("remote 相同版本 → false（非严格更新）") {
            XCTAssertFalse(compareVersions("0.1.9", "0.1.9"), "相同版本不应提示更新")
        }

        runTest("remote 更低版本 → false") {
            XCTAssertFalse(compareVersions("0.1.9", "0.1.8"), "旧版本不提示")
            XCTAssertFalse(compareVersions("0.2.0", "0.1.9"), "降级不提示")
        }

        runTest("缺位按 0 处理（1.9 vs 1.9.1）") {
            XCTAssertTrue(compareVersions("0.1.9", "0.1.9.1"), "1.9 < 1.9.1")
            XCTAssertTrue(compareVersions("1.9", "1.9.0.1"), "1.9 < 1.9.0.1")
        }

        runTest("patch 版本比较") {
            XCTAssertTrue(compareVersions("0.1.8", "0.1.9"), "patch 升级")
            XCTAssertTrue(compareVersions("0.1.9", "0.1.10"), "patch 两位")
            XCTAssertFalse(compareVersions("0.1.10", "0.1.9"), "10 > 9")
        }

        runTest("非数字段按 0 处理（健壮性）") {
            XCTAssertTrue(compareVersions("0.1.x", "0.1.9"), "非数字 local 段按 0")
            XCTAssertFalse(compareVersions("0.1.9", "0.1.x"), "非数字 remote 段按 0")
        }
    }
}
