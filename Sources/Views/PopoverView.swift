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
            // ── Header ──
            // Power icon, app title, and badge count
            HStack {
                Image(systemName: batteryMonitor.isOnBattery ? "battery.25" : "powerplug.fill")
                    .font(.title3)
                    .foregroundColor(batteryMonitor.isOnBattery ? .orange : .green)
                Text("BatKill")
                    .font(.headline)
                Spacer()
                badgeView
            }

            // ── Power Status Bar ──
            // Colored dot + battery percentage or "AC Power"
            HStack {
                Circle()
                    .fill(batteryMonitor.isOnBattery ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(powerText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
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
            // "Kill Now" button for immediate kill
            Button {
                processKiller.killSelected(appLister.apps) { appLister.refreshAppList() }
            } label: {
                Label(lm.translate("Kill Now", "立即停止"), systemImage: "bolt.fill")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(processKiller.isKilling
                || !appLister.apps.contains(where: { $0.isSelected && $0.isRunning }))

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
    private var badgeView: some View {
        let count = badgeCount
        return Group {
            if count > 0 {
                Text("\(count)")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(batteryMonitor.isOnBattery ? Color.orange : Color.blue)
                    .clipShape(Capsule())
            } else {
                Text("0")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
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
