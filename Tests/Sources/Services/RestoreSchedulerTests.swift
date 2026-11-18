//  RestoreSchedulerTests.swift
//  BatKill Tests
//
//  Tests for the v0.2.6 restore scheduler (REQ-018):
//    - `restoreInterval(forCPU:)` boundary mapping
//    - `isPowerContactIssue(...)` 10s-window detection (injectable clock)
//    - `restoreCancelled` interruption preserving un-restored apps

import Foundation

final class RestoreSchedulerTests: TestCase {
    let name = "RestoreSchedulerTests"

    /// Original persisted restore lists, restored in `tearDown` so these tests
    /// do not pollute the persisted state for other test cases.
    private var originalKilled: [String]?
    private var originalSuspended: [String]?

    func setUp() {
        originalKilled = UserDefaults.standard.stringArray(forKey: "killedRestorePaths")
        originalSuspended = UserDefaults.standard.stringArray(forKey: "suspendedPaths")
    }

    func tearDown() {
        if let originalKilled {
            UserDefaults.standard.set(originalKilled, forKey: "killedRestorePaths")
        } else {
            UserDefaults.standard.removeObject(forKey: "killedRestorePaths")
        }
        if let originalSuspended {
            UserDefaults.standard.set(originalSuspended, forKey: "suspendedPaths")
        } else {
            UserDefaults.standard.removeObject(forKey: "suspendedPaths")
        }
    }

    func run() {
        testRestoreIntervalBoundaries()
        testPowerContactIssue()
        testRestoreCancellation()
    }

    // MARK: - restoreInterval(forCPU:) boundaries

    func testRestoreIntervalBoundaries() {
        runTest("restoreInterval：<25 → 2s") {
            XCTAssertEqual(restoreInterval(forCPU: 24.9), 2)
            XCTAssertEqual(restoreInterval(forCPU: 0), 2)
            XCTAssertEqual(restoreInterval(forCPU: -1), 2, "负值按最近档（<25）处理")
        }

        runTest("restoreInterval：25 边界 → 4s") {
            XCTAssertEqual(restoreInterval(forCPU: 25), 4)
        }

        runTest("restoreInterval：49.9 → 4s") {
            XCTAssertEqual(restoreInterval(forCPU: 49.9), 4)
        }

        runTest("restoreInterval：50 边界 → 6s") {
            XCTAssertEqual(restoreInterval(forCPU: 50), 6)
        }

        runTest("restoreInterval：74.9 → 6s") {
            XCTAssertEqual(restoreInterval(forCPU: 74.9), 6)
        }

        runTest("restoreInterval：75 边界 → 10s") {
            XCTAssertEqual(restoreInterval(forCPU: 75), 10)
        }

        runTest("restoreInterval：100 → 10s（含超范围兜底）") {
            XCTAssertEqual(restoreInterval(forCPU: 100), 10)
            XCTAssertEqual(restoreInterval(forCPU: 200), 10, ">100 按最近档（>=75）处理")
        }
    }

    // MARK: - isPowerContactIssue(...)

    func testPowerContactIssue() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        runTest("接触不良：10s 内 3 次翻转 → true") {
            let flips = [now, now.addingTimeInterval(-2), now.addingTimeInterval(-5)]
            XCTAssertTrue(isPowerContactIssue(flipTimes: flips, now: now))
        }

        runTest("接触不良：10s 内 2 次翻转 → false") {
            let flips = [now, now.addingTimeInterval(-5)]
            XCTAssertFalse(isPowerContactIssue(flipTimes: flips, now: now))
        }

        runTest("接触不良：3 次但窗口外（>10s）→ false") {
            let flips = [now, now.addingTimeInterval(-6), now.addingTimeInterval(-12)]
            XCTAssertFalse(isPowerContactIssue(flipTimes: flips, now: now))
        }

        runTest("接触不良：恰好 3 次（含窗口边界 10s）→ true") {
            let flips = [now, now.addingTimeInterval(-4), now.addingTimeInterval(-10)]
            XCTAssertTrue(isPowerContactIssue(flipTimes: flips, now: now, window: 10, threshold: 3))
        }

        runTest("接触不良：空/单次 → false") {
            XCTAssertFalse(isPowerContactIssue(flipTimes: [], now: now))
            XCTAssertFalse(isPowerContactIssue(flipTimes: [now], now: now))
        }

        runTest("接触不良：阈值可调（4 次、阈值 2 → true；阈值 5 → false）") {
            let flips = [now, now.addingTimeInterval(-1), now.addingTimeInterval(-3), now.addingTimeInterval(-8)]
            XCTAssertTrue(isPowerContactIssue(flipTimes: flips, now: now, threshold: 2))
            XCTAssertFalse(isPowerContactIssue(flipTimes: flips, now: now, threshold: 5))
        }
    }

    // MARK: - Restore cancellation (restoreCancelled)

    func testRestoreCancellation() {
        runTest("恢复取消：cancelRestore 置位取消标志且幂等") {
            let killer = ProcessKiller()
            XCTAssertFalse(killer.restoreCancelled, "初始不应处于取消状态")
            killer.cancelRestore()
            XCTAssertTrue(killer.restoreCancelled, "cancelRestore 应置位取消标志")
            killer.cancelRestore()
            XCTAssertTrue(killer.restoreCancelled, "重复 cancelRestore 应保持置位")
        }

        runTest("恢复取消：restoreCancelled 中断保留未恢复项") {
            // Seed a pending restore list of three apps. The sleep hook cancels
            // the sequence during the wait after the first app restores; the
            // loop breaks at the next cancellation check and leaves the
            // un-restored app(s) in the pending list (AC-612/AC-613).
            let paths = ["/tmp/bk-test-A.app", "/tmp/bk-test-B.app", "/tmp/bk-test-C.app"]
            UserDefaults.standard.set(paths, forKey: "killedRestorePaths")
            UserDefaults.standard.removeObject(forKey: "suspendedPaths")

            let killer = ProcessKiller()
            var completed = false
            let hooks = RestoreTestHooks(sleep: { _ in killer.cancelRestore() })
            killer.restoreSequential(using: [], manual: true,
                                     testHooks: hooks,
                                     completion: { completed = true })

            // Pump the main run loop so queued main-thread work (state updates
            // + completion) can execute while the background sequence runs.
            let deadline = Date().addingTimeInterval(5)
            while !completed && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(completed, "恢复序列应完成")
            // Flush the completion's async UserDefaults write.
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            // `Set` ordering is non-deterministic, so the exact preserved item
            // is unknown -- but exactly the processed items are cleared and the
            // remaining item is preserved. All 3 are `.app` paths that always
            // "restore" (no real launch for non-existent paths), so 2 of 3 are
            // processed before the cancel takes effect.
            let remaining = UserDefaults.standard.stringArray(forKey: "killedRestorePaths") ?? []
            XCTAssertEqual(remaining.count, 1, "取消中断后应恰好保留 1 个未恢复项")
            XCTAssertTrue(paths.contains(remaining[0]), "保留项应为原始待恢复项之一")
            let restoredCount = paths.filter { !remaining.contains($0) }.count
            XCTAssertEqual(restoredCount, 2, "取消前已恢复的 2 项应从待恢复列表清除")

            XCTAssertFalse(killer.isRestoring, "恢复状态应复位")
            XCTAssertFalse(killer.restoreCancelled, "取消标志应在完成时复位")
            XCTAssertEqual(killer.restoreDone, 0, "进度计数应复位")
            XCTAssertEqual(killer.restoreTotal, 0, "进度总数应复位")
        }
    }
}
