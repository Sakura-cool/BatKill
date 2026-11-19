//  AppListerTests.swift
//  BatKill Tests
//
//  Tests for the pure self-exclusion rule used by app discovery (CHANGE-084).

import Foundation

final class AppListerTests: TestCase {
    let name = "AppListerTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        // The rule is exercised against the real app identifiers BatKill uses,
        // but with explicit self-path/bundle-id parameters so the test stays
        // independent of the test binary's own bundle.
        let selfPath = "/Applications/BatKill.app"
        let selfBundleID = "com.batkill.app"

        runTest("自身排除：bundleIdentifier 命中即排除（已安装形态）") {
            XCTAssertTrue(AppLister.isSelfApp(selfPath, bundleIdentifier: selfBundleID,
                                              selfPath: selfPath,
                                              selfBundleIdentifier: selfBundleID))
        }

        runTest("自身排除：bundleIdentifier 命中即使路径不同也排除") {
            XCTAssertTrue(AppLister.isSelfApp("/opt/BatKill/BatKill.app",
                                             bundleIdentifier: selfBundleID,
                                             selfPath: selfPath,
                                             selfBundleIdentifier: selfBundleID),
                          "bundleID 是稳定判据，路径变化不应放行自身")
        }

        runTest("自身排除：路径命中即排除（开发构建，bundleID 缺失时）") {
            XCTAssertTrue(AppLister.isSelfApp("/tmp/BatKill-arm64.app",
                                             bundleIdentifier: nil,
                                             selfPath: "/tmp/BatKill-arm64.app",
                                             selfBundleIdentifier: selfBundleID),
                          "开发构建的 .build 路径靠 selfPath 命中")
        }

        runTest("自身排除：路径命中即使 bundleIdentifier 不同也排除") {
            XCTAssertTrue(AppLister.isSelfApp(selfPath,
                                             bundleIdentifier: "com.other.app",
                                             selfPath: selfPath,
                                             selfBundleIdentifier: selfBundleID))
        }

        runTest("自身排除：既不命中路径也不命中 bundleID → 不排除") {
            XCTAssertFalse(AppLister.isSelfApp("/Applications/Safari.app",
                                              bundleIdentifier: "com.apple.Safari",
                                              selfPath: selfPath,
                                              selfBundleIdentifier: selfBundleID),
                          "正常应用必须保留在列表中")
        }

        runTest("自身排除：空 bundleIdentifier 不产生误判") {
            XCTAssertFalse(AppLister.isSelfApp("/Applications/Other.app",
                                              bundleIdentifier: "",
                                              selfPath: selfPath,
                                              selfBundleIdentifier: ""),
                          "双方 bundleID 皆空不得判为自身")
        }

        runTest("自身排除：空路径 + 空 selfPath 不产生误判") {
            XCTAssertFalse(AppLister.isSelfApp("", bundleIdentifier: nil,
                                              selfPath: "",
                                              selfBundleIdentifier: nil),
                          "双方路径皆空不得判为自身")
        }

        runTest("自身排除：bundleID 大小写敏感") {
            XCTAssertFalse(AppLister.isSelfApp("/Applications/Other.app",
                                              bundleIdentifier: "com.BatKill.App",
                                              selfPath: selfPath,
                                              selfBundleIdentifier: selfBundleID),
                          "bundleIdentifier 比较应大小写敏感")
        }
    }
}
