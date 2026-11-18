//  PopoverView.swift
//  BatKill
//
//  The compact popover panel shown when the user left-clicks the menu-bar
//  icon. Displays the current power status, a badge count, and a quick
//  action -- "Kill Now" on battery, or a subdivided restore entry
//  ("Restore Sequentially" + "Bulk Quick Restore") when apps are pending.
//
//  This is NOT the full settings window -- it is a lightweight status
//  dashboard. The full settings panel is hosted by SettingsView in a
//  separate NSWindow.
//
//  Architecture:
//    - Hosted inside an NSPanel (popover) by MenuBarManager
//    - Receives BatteryMonitor, AppLister, ProcessKiller, and
//      LocalizationManager as ObservedObjects (not EnvironmentObjects)
//    - Full settings panel is opened via right-click → "Show Window"

import AppKit
import SwiftUI

// MARK: - Popover Content (shown from menu bar)

/// Compact status popover displayed on left-click of the menu-bar icon.
/// Shows power state, badge count, and a quick action -- "Kill Now" on
/// battery, or a subdivided restore entry ("Restore Sequentially" +
/// "Bulk Quick Restore") when apps are pending.
struct PopoverView: View {

    // MARK: - Observed Objects

    /// Monitors battery/AC state and battery percentage.
    @ObservedObject var batteryMonitor: BatteryMonitor

    /// Provides the list of installed apps and their selection state.
    @ObservedObject var appLister: AppLister

    /// Manages kill/restore operations and pending restore count.
    @ObservedObject var processKiller: ProcessKiller

    /// Provides translations and the current language selection.
    @ObservedObject var lm: LocalizationManager

    // MARK: - Body

    var body: some View {
        VStack(spacing: 12) {
            // ── Power Status Bar ──
            // Colored dot + battery percentage or "AC Power", with the
            // power-source icon trailing the text and the badge on the right
            HStack(spacing: 6) {
                Circle()
                    .fill(batteryMonitor.isOnBattery ? Color.red : Color.green)
                    .frame(width: 8, height: 8)
                Text(powerText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Image(systemName: batteryMonitor.isOnBattery ? "battery.25" : "powerplug.fill")
                    .font(.caption)
                    .foregroundColor(batteryMonitor.isOnBattery ? .red : .green)
                    .accessibilityLabel(batteryMonitor.isOnBattery ? lm.translate("Battery", "电池") : lm.translate("AC Power", "交流电"))
                Spacer()
                badgeView
            }

            Divider()

            // ── Badge Explanation ──
            // Contextual text explaining what the badge number means
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: batteryMonitor.isOnBattery ? "arrow.triangle.2.circlepath" : "bolt.slash")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(explanationText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // ── Quick Action ──
            // On battery: a single "Kill Now" button. On AC with pending apps:
            // two restore actions -- "Restore Sequentially" (primary, filled
            // green) and "Bulk Quick Restore" (secondary, outlined green) --
            // subdividing the former single "Restore Now" button so the
            // status-bar popover matches the settings window's dual restore
            // entry (design-spec §1.2). Disabled while a kill/restore is in
            // flight to prevent rapid double-clicks.
            if shouldRestore {
                VStack(spacing: 6) {
                    // Sequential restore -- safe default (primary, filled green).
                    Button {
                        processKiller.restoreSequential(using: appLister.apps) { appLister.refreshAppList() }
                    } label: {
                        Label(lm.translate("Restore Sequentially", "依次恢复"),
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.green.opacity(quickActionDisabled ? 0.45 : 1.0))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .disabled(quickActionDisabled)
                    .help(lm.translate(
                        "Restore pending apps one at a time",
                        "依次恢复待恢复软件（逐个有序）"
                    ))

                    // Bulk quick restore -- secondary, outlined green; requires
                    // confirmation because launching many apps may stutter.
                    Button { confirmBulkRestore() } label: {
                        Label(lm.translate("Bulk Quick Restore", "批量快速恢复"),
                              systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundColor(Color.green.opacity(quickActionDisabled ? 0.45 : 1.0))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.green.opacity(quickActionDisabled ? 0.45 : 1.0), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(quickActionDisabled)
                    .help(lm.translate(
                        "Restore all pending apps at once (may stutter)",
                        "一次性恢复全部待恢复软件（可能造成卡顿）"
                    ))
                }
            } else {
                // Kill Now -- terminates selected running apps (red, filled).
                Button {
                    processKiller.killSelected(appLister.apps) { appLister.refreshAppList() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .frame(width: 14, alignment: .center)
                        Text(lm.translate("Kill Now", "立即停止"))
                    }
                    .font(.caption)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(quickActionDisabled ? 0.45 : 1.0))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(quickActionDisabled)
            }

            // ── Status Info ──
            // Total app count and running count summary
            Text(statusInfo)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 260)
    }

    // MARK: - Badge View

    /// Capsule-shaped badge in the top-right corner showing the pending
    /// restore count (matches the menu-bar icon badge and the pending list).
    /// Always occupies its slot (hidden via opacity at 0) so the popover
    /// layout never jumps when the count changes.
    private var badgeView: some View {
        Text("\(badgeCount)")
            .font(.caption).fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.green)
            .clipShape(Capsule())
            .opacity(badgeCount > 0 ? 1 : 0)
    }

    // MARK: - Quick Action State

    /// Whether the quick-action button should restore pending apps (true)
    /// or kill selected running apps (false).
    private var shouldRestore: Bool {
        processKiller.pendingRestoreCount > 0
    }

    /// Whether the quick-action button should be disabled: while a
    /// kill/restore is in flight (debounce), or when there is no
    /// actionable target for the current mode.
    private var quickActionDisabled: Bool {
        if processKiller.isKilling || processKiller.isRestoring { return true }
        if shouldRestore { return false }
        return !appLister.apps.contains(where: { $0.isSelected && $0.isRunning })
    }

    /// Presents the bulk-restore confirmation and, on confirm, restores all
    /// pending apps at once (AC-605 "may stutter" warning). Uses NSAlert
    /// rather than SwiftUI `.alert` because the popover is hosted in a
    /// non-activating NSPanel, where a SwiftUI alert may not reliably
    /// present; NSAlert is the design's established fallback for non-window
    /// contexts (design-spec §6.2).
    private func confirmBulkRestore() {
        let alert = NSAlert()
        alert.messageText = lm.translate(
            "Bulk restore may cause temporary stutter",
            "批量恢复可能造成短暂卡顿"
        )
        alert.informativeText = lm.translate(
            "Restore all pending apps now?",
            "确定立即恢复全部待恢复软件？"
        )
        alert.addButton(withTitle: lm.translate("Restore", "恢复"))
        alert.addButton(withTitle: lm.translate("Cancel", "取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            processKiller.restoreKilledApps(using: appLister.apps) { appLister.refreshAppList() }
        }
    }

    // MARK: - Computed Values

    /// Pending restore count — the badge always reflects "how many apps are
    /// still pending restore", independent of power state (matches the
    /// menu-bar icon badge and the pending list).
    private var badgeCount: Int {
        processKiller.pendingRestoreCount
    }

    /// Localized power source text with battery percentage.
    private var powerText: String {
        if batteryMonitor.isOnBattery {
            return lm.translate("Battery — \(Int(batteryMonitor.batteryPercentage))%", "电池 — \(Int(batteryMonitor.batteryPercentage))%")
        }
        return lm.translate("AC Power", "交流电")
    }

    /// Explains what the badge count means in the current power context.
    private var explanationText: String {
        if batteryMonitor.isOnBattery {
            return lm.translate(
                "\(badgeCount) app(s) will be killed on battery",
                "\(badgeCount) 个应用将在电池时停止"
            )
        } else {
            return lm.translate(
                "\(badgeCount) app(s) will restore on AC",
                "\(badgeCount) 个应用将在接电时恢复"
            )
        }
    }

    /// Summary line showing total app count and how many are running.
    private var statusInfo: String {
        let total = appLister.apps.count
        let running = appLister.apps.filter(\.isRunning).count
        return lm.translate("\(total) apps · \(running) running", "共 \(total) 个 · \(running) 运行中")
    }
}
