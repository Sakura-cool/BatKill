//  RestoreScheduler.swift
//  BatKill
//
//  v0.2.6 "恢复与启动约束" (REQ-018): sequential restore scheduler, progress /
//  gating state model, and the state-aware notification rewrite. Split out of
//  ProcessKiller.swift to keep that file under the SwiftLint file-length gate
//  (the project explicitly expects large files to be split, per .swiftlint.yml).
//
//  This file adds:
//    - `RestorePhase` / `RestoreGateState` / `RestoreNotificationMode` models
//    - `restoreInterval(forCPU:)` and `isPowerContactIssue(...)` pure functions
//    - `ProcessKiller.restoreSequential(using:manual:context:completion:)`
//    - `ProcessKiller.cancelRestore()`
//    - Strategy-grouped kill notification + mode-aware restore notification
//
//  The v0.2.5 kill/restore semantics (suspend/graceful/force dispatch,
//  terminate path, power-queue debounce/cooldown) are unchanged.

import Cocoa
import Foundation
import UserNotifications

// MARK: - Restore Phase (v0.2.6)

/// Phases of a sequential restore run, driving the UI progress caption
/// (design-spec §2.2). `idle` = no sequence active; `waiting` = sampling CPU
/// and sleeping before the next app; `restoring` = launching the current app.
enum RestorePhase: Equatable {
    case idle
    case waiting(intervalSec: Double)
    case restoring(name: String)
}

// MARK: - Restore Gate State (v0.2.6)

/// Gate state for the automatic restore path (low-battery / contact-issue /
/// in-progress). Drives the low-battery banner in SettingsView and
/// PendingRestoreSheet. Manual restore entries bypass this gate entirely.
enum RestoreGateState: Equatable {
    case idle
    case delayedLowBattery
    case restoring
    case completed
}

/// Why the low-battery gate is held, so UI can differentiate the banner copy:
/// an initial <20% on AC (">=20% 后自动恢复") vs a pause (AC-615/617 or
/// contact-issue "暂停") which reads "自动恢复已暂停" (design-spec §6.3 / S5).
enum RestoreGateReason: Equatable {
    case lowBattery
    case paused
    /// Contact-issue "Pause restore" (AC-614): the gate is held because the
    /// user chose to pause after a loose-power warning, NOT because of low
    /// battery — so the banner must not say "电量不足" (S5 文案误用修复).
    case contactIssue
}

// MARK: - Restore Notification Mode (v0.2.6)

/// Restore notification flavor: sequential (ordered, interval-paced) vs
/// batch (no interval, quick loop).
enum RestoreNotificationMode {
    case sequential
    case batch
}

// MARK: - Restore Interval Pure Function (v0.2.6)

/// Maps a system CPU usage percentage to a restore wait interval (seconds).
///
/// A busy system (high CPU) gets a longer interval so sequential restore does
/// not compound load spikes when relaunching many apps in a row. Pure function
/// (no side effects) so it is unit-testable; `switch` interval bounds clamp the
/// result to [2, 10].
///
/// - `..<25`: 2s, `..<50`: 4s, `..<75`: 6s, else 10s.
func restoreInterval(forCPU cpuUsage: Double) -> TimeInterval {
    switch cpuUsage {
    case ..<25:  return 2
    case ..<50:  return 4
    case ..<75:  return 6
    default:     return 10
    }
}

// MARK: - Power Contact Issue Pure Function (v0.2.6)

/// Detects a power contact issue: whether `flipTimes` contains `>= threshold`
/// AC/battery transitions within the trailing `window` seconds ending at `now`.
///
/// Pure function (injectable clock via `now`) so it is unit-testable.
/// The AppDelegate records each `isOnBattery` transition timestamp and calls
/// this after each flip; `>= 3` flips within 10s indicates a loose power
/// connection (design-spec §6.2 / AC-614).
func isPowerContactIssue(flipTimes: [Date], now: Date = Date(),
                         window: TimeInterval = 10, threshold: Int = 3) -> Bool {
    let cutoff = now.addingTimeInterval(-window)
    let recent = flipTimes.filter { $0 >= cutoff }.count
    return recent >= threshold
}

// MARK: - Low-battery gate + drain analysis (v0.2.6, AC-601/602/615-617)

/// The auto-restore gate decision: auto-restore is delayed while on AC and the
/// battery is below 20% (AC-601); it resumes at >=20% (AC-602). Manual restore
/// bypasses this entirely (AC-608/AC-618).
func shouldDelayAutoRestore(batteryPercentage: Double) -> Bool {
    batteryPercentage < 20
}

/// The charger's output is insufficient when the battery is below 80% yet still
/// draining while on AC power — the charger cannot keep up with system
/// consumption (AC-619). Distinct from the generic "电源不足" (AC-615): this
/// names the actionable root cause and asks the user to use a larger charger.
func shouldWarnChargerPower(batteryPercentage: Double, onAC: Bool, declining: Bool) -> Bool {
    batteryPercentage < 80 && onAC && declining
}

/// Result of analyzing the battery's recent trajectory over a sliding window.
struct BatteryDeltaStatus: Equatable {
    /// True when the battery is draining while on AC (weak charger / high
    /// consumption) -- a decline from the oldest snapshot to the newest.
    let declining: Bool
    /// True when the battery dropped >=5 percentage points within 10s (AC-616).
    let rapidDecline: Bool
}

/// Analyzes a sliding window of battery snapshots (already trimmed to 10s).
/// `onAC` means the Mac is on AC power; drain only matters there (on battery,
/// natural drain is expected and not flagged). Faithful to the AppDelegate
/// handler: declining = onAC && oldest > newest; rapid = span<=10s && delta<=-5.
func analyzeBatteryDelta(snapshots: [(time: Date, pct: Double)],
                         now: Date, onAC: Bool) -> BatteryDeltaStatus {
    guard onAC, let first = snapshots.first, let last = snapshots.last,
          first.pct > last.pct else {
        return BatteryDeltaStatus(declining: false, rapidDecline: false)
    }
    let delta = last.pct - first.pct
    let span = now.timeIntervalSince(first.time)
    return BatteryDeltaStatus(declining: true,
                              rapidDecline: span <= 10 && delta <= -5)
}

// MARK: - Ordered restore path union (v0.2.6, AC-603)

/// Order-preserving union of the killed (relaunch) and suspended (resume) ID
/// lists, keeping the first occurrence of each ID. `Array(Set(...))` would
/// destroy the stable "待恢复列表原顺序" contract (design-spec §1.3 / AC-603):
/// sequential restore must visit apps in the pending list's original order.
func orderedRestorePaths(_ killed: [String], _ suspended: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for path in killed + suspended where seen.insert(path).inserted {
        result.append(path)
    }
    return result
}

// MARK: - Kill notification grouping (v0.2.6, AC-609)

/// Grouped app names by pause strategy, used to compose a state-aware kill
/// notification (each app in exactly one group).
struct KillNotificationGroups: Equatable {
    let suspended: [String]
    let graceful: [String]
    let force: [String]
    let failed: [String]
}

/// Partitions killed apps by `suspendStrategy` (success) or failure, with
/// non-empty groups only -- the notification body lists each group on its own
/// line instead of a flat "已停止: list" (AC-609).
func groupKillNotifications(apps: [AppItem],
                            results: [String: Bool]) -> KillNotificationGroups {
    var suspended: [String] = []
    var graceful: [String] = []
    var force: [String] = []
    var failed: [String] = []
    for app in apps {
        guard let success = results[app.name] else { continue }
        if success {
            switch app.suspendStrategy {
            case .suspend:  suspended.append(app.name)
            case .graceful: graceful.append(app.name)
            case .force:    force.append(app.name)
            }
        } else {
            failed.append(app.name)
        }
    }
    return KillNotificationGroups(suspended: suspended, graceful: graceful,
                                  force: force, failed: failed)
}

// MARK: - Restore Test Hooks (v0.2.6)

/// Injectable dependencies for `restoreSequential`, used only by unit tests to
/// drive deterministic cancellation / pacing without real CPU sampling or
/// thread sleeps. Production callers use the default (real) hooks.
struct RestoreTestHooks {
    /// Overrides CPU sampling; `nil` uses the real `SystemLoadReader`.
    var loadSampler: (() -> Double)?
    /// Wait between apps; defaults to a real `Thread.sleep`.
    var sleep: (TimeInterval) -> Void
    /// Suppress the completion notification. Unit tests cannot post real
    /// `UserNotifications` (the test binary has no app bundle / notification
    /// context), so tests that complete a sequence set this to avoid the
    /// `UNUserNotificationCenter.current()` trap. Production defaults to `false`.
    var suppressCompletionNotification: Bool

    init(loadSampler: (() -> Double)? = nil,
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         suppressCompletionNotification: Bool = false) {
        self.loadSampler = loadSampler
        self.sleep = sleep
        self.suppressCompletionNotification = suppressCompletionNotification
    }
}

// MARK: - ProcessKiller: Restore Scheduler (v0.2.6)

extension ProcessKiller {

    /// Restores ALL pending apps one at a time, ordered, paced by system load.
    ///
    /// Serves BOTH the automatic path (AC power detected, AppDelegate) and the
    /// manual "Restore Sequentially" button (AC-606). Each app after the first
    /// is preceded by a CPU-usage sample (`SystemLoadReader`) and a
    /// `restoreInterval(forCPU:)` sleep so the restore does not compound load
    /// spikes (tech-solution §4).
    ///
    /// Cancellation: `cancelRestore()` sets `restoreCancelled`; the loop breaks
    /// at the next iteration and leaves un-restored apps in the pending list
    /// (AC-612/AC-613). Restored apps are cleared from both lists.
    ///
    /// - Parameters:
    ///   - apps: Full app list used to resolve display names / PIDs.
    ///   - manual: Whether this is a manual entry (ignores auto gate/pause).
    ///   - context: Structured logging context.
    ///   - testHooks: Injectable test dependencies (defaults to real hooks).
    ///   - completion: Called on the main thread when the sequence finishes
    ///     (completes, is cancelled, or is superseded by a newer run).
    func restoreSequential(using apps: [AppItem], manual: Bool = true,
                           context: LogContext? = nil,
                           testHooks: RestoreTestHooks = RestoreTestHooks(),
                           completion: (() -> Void)? = nil) {
        let ctx = context ?? LogContext(name: "restoreSequential")
        // Union of killed apps (relaunch) and suspended apps (SIGCONT resume),
        // preserving the pending list's order for a stable, ordered sequence.
        let paths = orderedRestorePaths(killedRestorePaths, suspendedPaths)
        guard !paths.isEmpty else {
            ctx.log("没有需要恢复的应用")
            DispatchQueue.main.async { completion?() }
            return
        }
        ctx.log("开始依次恢复 \(paths.count) 个应用")

        manualRestoreOverride = manual
        restoreCancelled = false
        let session = restoreSession + 1
        restoreSession = session
        isRestoring = true
        restoreGateState = .restoring
        restoreTotal = paths.count
        restoreDone = 0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let loadReader = SystemLoadReader()
            var restoredIds: [String] = []

            for (i, appId) in paths.enumerated() {
                // Snapshot the cancellation flag once per iteration. It is
                // written on the main thread (`cancelRestore`/`killSelected`)
                // and read here on the background queue; `Bool` is word-size
                // aligned so single-byte reads are atomic on arm64/x86_64, but
                // we avoid repeatedly re-reading a cross-thread value.
                let cancelled = self.restoreCancelled
                // Cancellation: break and leave the remaining apps pending.
                if cancelled {
                    ctx.log("依次恢复被取消，保留剩余 \(paths.count - i) 个未恢复项")
                    break
                }

                // First app restores immediately; later apps are load-paced.
                if i > 0 {
                    let cpu = testHooks.loadSampler?() ?? loadReader.currentUsage()
                    let interval = restoreInterval(forCPU: cpu)
                    let nextName = self.displayName(for: appId, using: apps)
                    DispatchQueue.main.async {
                        self.restorePhase = .waiting(intervalSec: interval)
                        self.nextRestoreName = nextName
                    }
                    ctx.log("等待 \(Int(interval))s 再恢复下一个（CPU \(Int(cpu))%）")
                    testHooks.sleep(interval)
                }

                let name = self.displayName(for: appId, using: apps)
                DispatchQueue.main.async {
                    self.restorePhase = .restoring(name: name)
                    self.nextRestoreName = name
                }
                let restoreCtx = ctx.child("restoreSingle")
                if let restoredName = self.restoreSingleApp(appId, using: apps) {
                    restoredIds.append(appId)
                    restoreCtx.log("恢复 \(restoredName) 成功")
                } else {
                    restoreCtx.log("恢复 \(appId) 失败")
                }
                DispatchQueue.main.async {
                    self.restoreDone = i + 1
                }
            }

            ctx.complete(success: true, extra: "\(restoredIds.count)/\(paths.count) 成功")

            DispatchQueue.main.async {
                if !restoredIds.isEmpty {
                    // Clear restored ids from both the relaunch and resume sets.
                    var remainingKilled = self.killedRestorePaths
                    remainingKilled.removeAll { restoredIds.contains($0) }
                    self.killedRestorePaths = remainingKilled
                    var remainingSuspended = self.suspendedPaths
                    remainingSuspended.removeAll { restoredIds.contains($0) }
                    self.suspendedPaths = remainingSuspended
                }
                // A stale sequence (superseded by a newer start) must not clobber
                // the newer run's state; its list cleanup above is still applied.
                guard self.restoreSession == session else {
                    completion?()
                    return
                }
                self.restoreCount += restoredIds.count
                let wasCancelled = self.restoreCancelled
                self.restoreCancelled = false
                self.manualRestoreOverride = false
                self.isRestoring = false
                self.restorePhase = .idle
                self.nextRestoreName = nil
                // Preserve an externally-set low-battery gate (AC-617) so a
                // sequence completion does not clear the "auto-restore paused"
                // banner that the battery-percentage handler set mid-sequence.
                if self.restoreGateState != .delayedLowBattery {
                    self.restoreGateState = (wasCancelled || restoredIds.isEmpty) ? .idle : .completed
                }
                self.restoreTotal = 0
                self.restoreDone = 0
                if !restoredIds.isEmpty && !wasCancelled && !testHooks.suppressCompletionNotification {
                    self.postRestoreNotification(mode: .sequential, count: restoredIds.count)
                }
                completion?()
            }
        }
    }

    /// Cancels the in-flight restore sequence.
    ///
    /// Sets `restoreCancelled` (checked each loop iteration); the loop breaks
    /// and leaves un-restored apps in the pending list. Resets `isRestoring` and
    /// `restorePhase` on the main thread so the UI unlocks promptly (AC-612/613).
    ///
    /// Called by AppDelegate when the user stops selected apps or unplugs power
    /// while a restore is running. Idempotent and safe when no restore is
    /// active. The main-thread reset is session-guarded so it can never clobber
    /// a restore that started after the cancel request.
    func cancelRestore() {
        guard !restoreCancelled else { return }
        restoreCancelled = true
        let session = restoreSession
        logger("cancelRestore: 请求中断恢复序列")
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.restoreSession == session else { return }
            self.isRestoring = false
            self.restorePhase = .idle
        }
    }

    // MARK: - Notifications (v0.2.6)

    /// Posts a user notification summarizing which apps were killed, grouped by
    /// the per-app suspend strategy (suspend / graceful / force), plus any that
    /// failed. Each app is assigned to exactly one group by its
    /// `suspendStrategy`; empty groups are omitted (design-spec §5.1 / AC-609).
    func postKillNotification(apps: [AppItem], results: [String: Bool]) {
        let groups = groupKillNotifications(apps: apps, results: results)

        var bodyParts: [String] = []
        if !groups.suspended.isEmpty {
            bodyParts.append(loc("Suspended: %@", "已挂起：%@", groups.suspended.joined(separator: ", ")))
        }
        if !groups.graceful.isEmpty {
            bodyParts.append(loc("Gracefully quit: %@", "已优雅退出：%@", groups.graceful.joined(separator: ", ")))
        }
        if !groups.force.isEmpty {
            bodyParts.append(loc("Force quit: %@", "已强制退出：%@", groups.force.joined(separator: ", ")))
        }
        if !groups.failed.isEmpty {
            bodyParts.append(loc("Failed: %@", "失败：%@", groups.failed.joined(separator: ", ")))
        }
        let body = bodyParts.joined(separator: "\n")
        guard !body.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "BatKill"
        content.body = body
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Posts a completion notification for a sequential or batch restore,
    /// differentiated by mode (design-spec §5.2 / AC-610).
    func postRestoreNotification(mode: RestoreNotificationMode, count: Int) {
        guard count > 0 else { return }
        let body: String
        switch mode {
        case .sequential:
            body = loc("Sequential restore complete: restored %d", "依次恢复完成：已恢复 %d 个", count)
        case .batch:
            body = loc("Bulk restore complete: restored %d", "批量恢复完成：已恢复 %d 个", count)
        }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "BatKill"
        content.body = body
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Posts a user notification listing the names of apps restored (single /
    /// selective restore paths). Retained for v0.2.5 semantics of
    /// `restorePendingSingle` and `restoreSelected`.
    func postRestoreNotification(names: [String]) {
        guard !names.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "BatKill"
        content.body = loc("✅ Restored on AC:", "✅ 已恢复:") + " " + names.joined(separator: ", ")
        content.sound = .default

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }
}
