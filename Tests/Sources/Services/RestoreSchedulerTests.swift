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
        testGateDecision()
        testBatteryDeltaAnalysis()
        testChargerPowerWarning()
        testSerialScheduling()
        testNotificationGrouping()
        testOrderedRestorePaths()
        testPowerSlopePacing()
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

            // Order is deterministic (`orderedRestorePaths` preserves the pending
            // list order); the cancel lands during the wait after the first
            // app, so the first two are processed and the third is preserved.
            // All 3 are `.app` paths that always
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

    // MARK: - Low-battery gate decision (UT-011 / UT-012, AC-601/602)

    func testGateDecision() {
        runTest("门控：<20% → 延缓自动恢复") {
            XCTAssertTrue(shouldDelayAutoRestore(batteryPercentage: 0))
            XCTAssertTrue(shouldDelayAutoRestore(batteryPercentage: 19.9))
        }
        runTest("门控：=20%（含边界）→ 不延缓（进入恢复）") {
            XCTAssertFalse(shouldDelayAutoRestore(batteryPercentage: 20))
            XCTAssertFalse(shouldDelayAutoRestore(batteryPercentage: 50))
            XCTAssertFalse(shouldDelayAutoRestore(batteryPercentage: 100))
        }
    }

    // MARK: - Battery drain analysis (UT-015 / UT-016, AC-615/616)

    func testBatteryDeltaAnalysis() {
        let now = Date()
        func snap(_ pcts: [Double], at offsets: [TimeInterval]) -> [(time: Date, pct: Double)] {
            zip(pcts, offsets).map { (time: now.addingTimeInterval($1), pct: $0) }
        }

        runTest("电量Δ：接电且下降 → declining，非快速（Δ<5%/10s）") {
            let s = snap([50, 48], at: [-8, 0])   // 10s 内降 2 点
            let r = analyzeBatteryDelta(snapshots: s, now: now, onAC: true)
            XCTAssertTrue(r.declining)
            XCTAssertFalse(r.rapidDecline)
        }
        runTest("电量Δ：快速下降（Δ≥5%/10s）→ rapidDecline") {
            let s = snap([50, 44.9], at: [-9, 0])  // 9s 内降 5.1 点
            let r = analyzeBatteryDelta(snapshots: s, now: now, onAC: true)
            XCTAssertTrue(r.declining)
            XCTAssertTrue(r.rapidDecline)
        }
        runTest("电量Δ：Δ=5 恰好 10s → rapid（含边界）") {
            let s = snap([50, 45], at: [-10, 0])
            let r = analyzeBatteryDelta(snapshots: s, now: now, onAC: true)
            XCTAssertTrue(r.rapidDecline)
        }
        runTest("电量Δ：窗口外（>10s 且 Δ≥5）→ 非 rapid") {
            let s = snap([50, 44.9], at: [-11, 0])
            let r = analyzeBatteryDelta(snapshots: s, now: now, onAC: true)
            XCTAssertTrue(r.declining)
            XCTAssertFalse(r.rapidDecline)
        }
        runTest("电量Δ：电池供电（非接电）→ 不标记（自然耗电预期）") {
            let s = snap([50, 44.9], at: [-9, 0])
            let r = analyzeBatteryDelta(snapshots: s, now: now, onAC: false)
            XCTAssertFalse(r.declining)
            XCTAssertFalse(r.rapidDecline)
        }
        runTest("电量Δ：上涨/空窗口 → 不标记") {
            let up = snap([44.9, 50], at: [-9, 0])
            XCTAssertFalse(analyzeBatteryDelta(snapshots: up, now: now, onAC: true).declining)
            XCTAssertFalse(analyzeBatteryDelta(snapshots: [], now: now, onAC: true).declining)
        }
    }

    // MARK: - Charger power warning (AC-619)

    func testChargerPowerWarning() {
        runTest("充电器功率：<80% + 接电 + 下降 → 警告") {
            XCTAssertTrue(shouldWarnChargerPower(batteryPercentage: 0, onAC: true, declining: true))
            XCTAssertTrue(shouldWarnChargerPower(batteryPercentage: 79.9, onAC: true, declining: true))
        }
        runTest("充电器功率：=80%（含边界）→ 不警告") {
            XCTAssertFalse(shouldWarnChargerPower(batteryPercentage: 80, onAC: true, declining: true))
            XCTAssertFalse(shouldWarnChargerPower(batteryPercentage: 100, onAC: true, declining: true))
        }
        runTest("充电器功率：电池供电（非接电）→ 不警告") {
            XCTAssertFalse(shouldWarnChargerPower(batteryPercentage: 50, onAC: false, declining: true))
        }
        runTest("充电器功率：电量上升（非下降）→ 不警告") {
            XCTAssertFalse(shouldWarnChargerPower(batteryPercentage: 50, onAC: true, declining: false))
        }
    }

    // MARK: - Serial scheduling (UT-017, AC-603/604)

    func testSerialScheduling() {
        runTest("依次调度：串行有序 + CPU 感知间隔（每段时间一个）") {
            let paths = ["/tmp/bk-seq-A.app", "/tmp/bk-seq-B.app", "/tmp/bk-seq-C.app"]
            UserDefaults.standard.set(paths, forKey: "killedRestorePaths")
            UserDefaults.standard.removeObject(forKey: "suspendedPaths")

            let killer = ProcessKiller()
            var sleepIntervals: [TimeInterval] = []
            let cpuSamples: [Double] = [10, 80]   // 两个间隔：10%→2s, 80%→10s
            var cpuIdx = 0
            var completed = false
            let hooks = RestoreTestHooks(
                loadSampler: {
                    let v = cpuSamples[min(cpuIdx, cpuSamples.count - 1)]
                    cpuIdx += 1
                    return v
                },
                sleep: { sleepIntervals.append($0) },
                suppressCompletionNotification: true)
            killer.restoreSequential(using: [], manual: true, testHooks: hooks,
                                     completion: { completed = true })

            let deadline = Date().addingTimeInterval(5)
            while !completed && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            XCTAssertTrue(completed, "恢复序列应完成")
            XCTAssertEqual(sleepIntervals.count, 2, "3 个应用间应有 2 次间隔等待")
            XCTAssertEqual(sleepIntervals[0], 2, "CPU 10% → 间隔 2s")
            XCTAssertEqual(sleepIntervals[1], 10, "CPU 80% → 间隔 10s")
            XCTAssertEqual(cpuIdx, 2, "两个间隔各采样一次 CPU")
            XCTAssertFalse(killer.isRestoring, "恢复状态应复位")
            XCTAssertEqual(killer.restoreDone, 0, "进度计数应复位")
            XCTAssertEqual(killer.restoreTotal, 0, "进度总数应复位")
        }
    }

    // MARK: - Kill notification grouping (UT-018, AC-609)
    func testNotificationGrouping() {
        runTest("通知分组：按暂停方式分组 + 失败组") {
            let apps = [
                AppItem(name: "A", bundleIdentifier: nil, path: "/A.app",
                        processName: "A", isSelected: true, isSystemApp: false,
                        category: .application, serviceLabel: nil,
                        suspendStrategy: .suspend),
                AppItem(name: "B", bundleIdentifier: nil, path: "/B.app",
                        processName: "B", isSelected: true, isSystemApp: false,
                        category: .application, serviceLabel: nil,
                        suspendStrategy: .graceful),
                AppItem(name: "C", bundleIdentifier: nil, path: "/C.app",
                        processName: "C", isSelected: true, isSystemApp: false,
                        category: .application, serviceLabel: nil,
                        suspendStrategy: .force),
                AppItem(name: "D", bundleIdentifier: nil, path: "/D.app",
                        processName: "D", isSelected: true, isSystemApp: false,
                        category: .application, serviceLabel: nil,
                        suspendStrategy: .graceful)
            ]
            let results: [String: Bool] = ["A": true, "B": true, "C": false, "D": true, "E": true]
            let groups = groupKillNotifications(apps: apps, results: results)
            XCTAssertEqual(groups.suspended, ["A"], "挂起组")
            XCTAssertEqual(groups.graceful, ["B", "D"], "优雅组（保序）")
            XCTAssertEqual(groups.force, [], "强制组（C 失败，不入成功组）")
            XCTAssertEqual(groups.failed, ["C"], "失败组")
        }
        runTest("通知分组：成功全挂起 → 仅挂起组非空") {
            let apps = [
                AppItem(name: "X", bundleIdentifier: nil, path: "/X.app",
                        processName: "X", isSelected: true, isSystemApp: false,
                        category: .application, serviceLabel: nil,
                        suspendStrategy: .suspend)
            ]
            let groups = groupKillNotifications(apps: apps, results: ["X": true])
            XCTAssertEqual(groups.suspended, ["X"])
            XCTAssertTrue(groups.graceful.isEmpty)
            XCTAssertTrue(groups.force.isEmpty)
            XCTAssertTrue(groups.failed.isEmpty)
        }
        runTest("通知分组：空结果 → 全空（无 body）") {
            let groups = groupKillNotifications(apps: [], results: [:])
            XCTAssertTrue(groups.suspended.isEmpty)
            XCTAssertTrue(groups.graceful.isEmpty)
            XCTAssertTrue(groups.force.isEmpty)
            XCTAssertTrue(groups.failed.isEmpty)
        }
    }

    // MARK: - Ordered restore path union (S3, AC-603)

    func testOrderedRestorePaths() {
        runTest("保序并集：保留待恢复列表原顺序（killed 先，suspended 后）") {
            let paths = orderedRestorePaths(
                ["/A.app", "/B.app", "/C.app"],
                ["/B.app", "/D.app"])
            XCTAssertEqual(paths, ["/A.app", "/B.app", "/C.app", "/D.app"],
                           "应保留 killed 顺序 + suspended 去重追加，不因 Set 打乱")
        }
        runTest("保序并集：空列表 → 空") {
            XCTAssertEqual(orderedRestorePaths([], []), [])
        }
        runTest("保序并集：仅 suspended") {
            XCTAssertEqual(orderedRestorePaths([], ["/X.app", "/Y.app"]), ["/X.app", "/Y.app"])
        }
        runTest("保序并集：完全重叠 → killed 顺序（无重复）") {
            XCTAssertEqual(orderedRestorePaths(["/A.app", "/B.app"], ["/A.app", "/B.app"]),
                           ["/A.app", "/B.app"])
        }
    }

    // MARK: - Power-slope restore pacing (v0.2.6, AC-620)

    func testPowerSlopePacing() {
        // allowedPowerSlope: dynamic, never hard-coded. Healthy + ample headroom
        // must permit a higher slope than aged / low-charge / tight-headroom states.
        let ample = allowedPowerSlope(headroomW: 15, batteryHealth: 1.0, batteryLevel: 1.0)
        let tight = allowedPowerSlope(headroomW: 0, batteryHealth: 1.0, batteryLevel: 1.0)
        let aged  = allowedPowerSlope(headroomW: 15, batteryHealth: 0.5, batteryLevel: 1.0)
        let low   = allowedPowerSlope(headroomW: 15, batteryHealth: 1.0, batteryLevel: 0.2)
        runTest("坡度：健康+富余 > 紧余量/老化/低电量（动态，非写死）") {
            XCTAssertGreaterThan(ample, tight)
            XCTAssertGreaterThan(ample, aged)
            XCTAssertGreaterThan(ample, low)
        }
        // Clamping: negative headroom treated as 0; >15W capped at full factor.
        runTest("坡度：负余量按 0 处理，>15W 封顶") {
            XCTAssertEqual(allowedPowerSlope(headroomW: -5, batteryHealth: 1, batteryLevel: 1),
                           allowedPowerSlope(headroomW: 0, batteryHealth: 1, batteryLevel: 1))
            XCTAssertEqual(allowedPowerSlope(headroomW: 99, batteryHealth: 1, batteryLevel: 1),
                           allowedPowerSlope(headroomW: 15, batteryHealth: 1, batteryLevel: 1))
        }
        // Monotonic in each runtime factor.
        runTest("坡度：各因子单调不减") {
            XCTAssertLessThanOrEqual(
                allowedPowerSlope(headroomW: 5, batteryHealth: 0.6, batteryLevel: 0.6),
                allowedPowerSlope(headroomW: 10, batteryHealth: 0.6, batteryLevel: 0.6))
            XCTAssertLessThanOrEqual(
                allowedPowerSlope(headroomW: 5, batteryHealth: 0.5, batteryLevel: 0.8),
                allowedPowerSlope(headroomW: 5, batteryHealth: 0.9, batteryLevel: 0.8))
            XCTAssertLessThanOrEqual(
                allowedPowerSlope(headroomW: 5, batteryHealth: 0.8, batteryLevel: 0.4),
                allowedPowerSlope(headroomW: 5, batteryHealth: 0.8, batteryLevel: 0.9))
        }
        // powerRestoreInterval: steep slope lengthens, gentle shortens; clamp [2,20].
        runTest("间隔：陡坡 > 缓坡；紧余量放大；夹在 [2,20]") {
            let steep = powerRestoreInterval(currentPowerW: 10, chargerWatts: 65,
                                             batteryHealth: 1, batteryLevel: 1, measuredSlope: 20)
            let gentle = powerRestoreInterval(currentPowerW: 10, chargerWatts: 65,
                                              batteryHealth: 1, batteryLevel: 1, measuredSlope: 0.1)
            XCTAssertGreaterThan(steep, gentle)
            let tightHeadroom = powerRestoreInterval(currentPowerW: 60, chargerWatts: 65,
                                                     batteryHealth: 1, batteryLevel: 1, measuredSlope: 0)
            let looseHeadroom = powerRestoreInterval(currentPowerW: 10, chargerWatts: 65,
                                                     batteryHealth: 1, batteryLevel: 1, measuredSlope: 0)
            XCTAssertGreaterThanOrEqual(tightHeadroom, looseHeadroom)
            XCTAssertGreaterThanOrEqual(gentle, 2)
            XCTAssertLessThanOrEqual(steep, 20)
        }
        // Degraded fallback: zero headroom + steep slope caps at the 20s ceiling.
        runTest("间隔：零余量+陡坡 → 上限 20s") {
            let worst = powerRestoreInterval(currentPowerW: 65, chargerWatts: 65,
                                             batteryHealth: 0.3, batteryLevel: 0.1, measuredSlope: 99)
            XCTAssertEqual(worst, 20)
        }
    }
}
