//  PopoverView.swift
//  BatKill
//
//  The compact popover panel shown when the user left-clicks the menu-bar
//  icon. Displays the current power status, a badge count, and a quick
//  "Kill Now" button.
//
//  This is NOT the full settings window -- it is a lightweight status
//  dashboard. The full settings panel is hosted by SettingsView in a
//  separate NSWindow.
//
//  Architecture:
//    - Hosted inside an NSPopover by MenuBarManager
//    - Receives BatteryMonitor, AppLister, ProcessKiller, and
//      LocalizationManager as ObservedObjects (not EnvironmentObjects)
//    - Full settings panel is opened via right-click → "Show Window"

import SwiftUI

// MARK: - Popover Content (shown from menu bar)

/// Compact status popover displayed on left-click of the menu-bar icon.
/// Shows power state, badge count, and a quick "Kill Now" button.
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
            // Toggles between "Kill Now" (stop selected running apps) and
            // "Restore Now" (relaunch pending apps). The button stays in
            // place and only swaps its label/action, so the popover layout
            // never jumps. Disabled while a kill/restore is in flight to
            // prevent rapid double-clicks.
            Button {
                if shouldRestore {
                    processKiller.restoreKilledApps(using: appLister.apps) { appLister.refreshAppList() }
                } else {
                    processKiller.killSelected(appLister.apps) { appLister.refreshAppList() }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: shouldRestore ? "arrow.clockwise" : "bolt.fill")
                        .frame(width: 14, alignment: .center)
                    Text(shouldRestore
                        ? lm.translate("Restore Now", "立即恢复")
                        : lm.translate("Kill Now", "立即停止"))
                }
                .font(.caption)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(quickActionColor.opacity(quickActionDisabled ? 0.45 : 1.0))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(quickActionDisabled)

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

    /// Capsule-shaped badge in the top-right corner showing either the
    /// kill count (on battery) or the pending restore count (on AC).
    /// Always occupies its slot (hidden via opacity at 0) so the popover
    /// layout never jumps when the count changes.
    private var badgeView: some View {
        Text("\(badgeCount)")
            .font(.caption).fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(batteryMonitor.isOnBattery ? Color.red : Color.green)
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

    /// Fill color for the quick-action button: red for "Kill Now", green
    /// for "Restore Now".
    private var quickActionColor: Color {
        shouldRestore ? .green : .red
    }

    // MARK: - Computed Values

    /// Number of selected-and-running apps (on battery) or pending
    /// restore apps (on AC).
    private var badgeCount: Int {
        if batteryMonitor.isOnBattery {
            return appLister.apps.filter { $0.isSelected && $0.isRunning }.count
        } else {
            return processKiller.pendingRestoreCount
        }
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
