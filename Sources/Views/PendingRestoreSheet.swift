//  PendingRestoreSheet.swift
//  BatKill
//
//  A sheet that lists apps waiting to be restored after the power source
//  switches from battery back to AC. Each row provides a "Delete" button
//  (removes from the pending list without restoring) and a "Restore"
//  button (launches the app immediately).
//
//  Presented from the bottom bar of SettingsView when the user taps the
//  pending-restore count label.
//
//  Extracted from ContentView.swift (originally `private struct PendingRestoreSheet`).
//  Access level changed from private to internal.

import SwiftUI

// MARK: - Pending Restore Sheet

/// A modal sheet displaying applications that were terminated on battery
/// and are waiting to be restored when AC power returns.
struct PendingRestoreSheet: View {
    /// The process killer that tracks pending restore IDs.
    @ObservedObject var processKiller: ProcessKiller

    /// The app list, used to resolve app names from IDs and for restore.
    @ObservedObject var appLister: AppLister

    /// Localization manager for translating labels.
    @ObservedObject var lm: LocalizationManager

    /// Environment dismiss action to close the sheet.
    @Environment(\.dismiss) private var dismiss

    /// Controls presentation of the "Bulk Quick Restore" confirmation alert.
    @State private var showBulkRestoreConfirm = false

    // MARK: - Computed

    /// True when the low-battery auto-restore gate is active (auto-restore
    /// delayed below 20% while on AC). Drives the gate banner; the manual
    /// restore buttons stay enabled regardless (AC-601/AC-608).
    private var isRestoreGateDelayed: Bool {
        if case .delayedLowBattery = processKiller.restoreGateState { return true }
        return false
    }

    /// Banner copy differentiated by why the gate is held (design-spec §6.3):
    /// an initial <20% on AC vs a pause (AC-615/617 / contact-issue).
    private var restoreGateHintText: String {
        switch processKiller.restoreGateReason {
        case .paused:
            return lm.translate("Battery low, auto-restore paused", "电量不足，自动恢复已暂停")
        case .lowBattery:
            return lm.translate("Battery low, auto-restore resumes at ≥20%", "电量不足，≥20% 后自动恢复")
        case .contactIssue:
            return lm.translate("Power contact unstable, auto-restore paused", "电源接触不良，自动恢复已暂停")
        }
    }

    /// Resolves each pending restore ID into a display tuple of
    /// (id, display name, category, isSuspended). Falls back to the file's
    /// last path component if the app is no longer in the app list.
    private var pendingApps: [(id: String, name: String, category: AppCategory, isSuspended: Bool)] {
        processKiller.pendingRestoreAppIds.compactMap { appId in
            if let app = appLister.apps.first(where: { $0.id == appId }) {
                return (appId, app.name, app.category, processKiller.suspendedAppIds.contains(appId))
            }
            return (appId, (appId as NSString).lastPathComponent, .custom, processKiller.suspendedAppIds.contains(appId))
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and count
            HStack {
                Text(lm.translate("Pending Restore", "待恢复程序"))
                    .font(.headline)
                Spacer()
                Text("\(pendingApps.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            // Low-battery gate banner (main position) -- shown while auto-restore
            // is delayed below 20% and there are pending apps to restore.
            if isRestoreGateDelayed && !pendingApps.isEmpty {
                gateBanner
            }

            Divider()

            // Content: empty state or scrollable list
            if pendingApps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text(lm.translate("Nothing pending", "没有待恢复的程序"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pendingApps, id: \.id) { item in
                            HStack(spacing: 8) {
                                // Category icon
                                Image(systemName: systemIcon(for: item.category))
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, height: 20)

                                // Name + category label + pending type
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    HStack(spacing: 4) {
                                        Text(categoryLabel(for: item.category))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        // Distinguish suspended (SIGCONT resume) from
                                        // killed (relaunch) pending apps.
                                        Text(item.isSuspended
                                             ? lm.translate("Suspended · will resume", "已挂起 · 待解冻")
                                             : lm.translate("Stopped · will relaunch", "已停止 · 待重启"))
                                            .font(.caption2)
                                            .foregroundColor(item.isSuspended ? .yellow : .secondary)
                                    }
                                }

                                Spacer()

                                // Delete -- removes from pending list without restoring.
                                // For a suspended (SIGSTOP-frozen) app, this also
                                // terminates the frozen process outright (deleting
                                // means the user no longer wants it resumed).
                                Button {
                                    withAnimation {
                                        processKiller.removePending(item.id, using: appLister.apps)
                                    }
                                } label: {
                                    Text(lm.translate("Delete", "删除"))
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)

                                // Restore -- launches the app immediately
                                Button {
                                    processKiller.restorePendingSingle(item.id, using: appLister.apps)
                                    appLister.refreshAppList()
                                } label: {
                                    Text(lm.translate("Restore", "恢复"))
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.green)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)

                            if item.id != pendingApps.last?.id {
                                Divider().padding(.leading, 36)
                            }
                        }
                    }
                }
            }

            // Restore progress row (shared with SettingsView, §4.2). Vertical
            // padding keeps it clear of the list above and the divider below.
            if processKiller.isRestoring {
                RestoreProgressRow(processKiller: processKiller, lm: lm)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }

            Divider()

            // Bottom action area: sequential / bulk restore + Done.
            // Sequential is the safe default (no confirmation); bulk restore
            // requires confirmation since it may cause a brief stutter.
            HStack(spacing: 8) {
                Button {
                    processKiller.restoreSequential(using: appLister.apps) { appLister.refreshAppList() }
                } label: {
                    Text(lm.translate("Restore Sequentially", "依次恢复"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(processKiller.isRestoring || pendingApps.isEmpty)

                Button { showBulkRestoreConfirm = true } label: {
                    Text(lm.translate("Bulk Quick Restore", "批量快速恢复"))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(processKiller.isRestoring || pendingApps.isEmpty)

                Spacer()

                Button(lm.translate("Done", "完成")) {
                    appLister.refreshAppList()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
        }
        .frame(width: 400, height: 400)
        .alert(
            lm.translate("Bulk restore may cause temporary stutter", "批量恢复可能造成短暂卡顿"),
            isPresented: $showBulkRestoreConfirm
        ) {
            Button(lm.translate("Cancel", "取消"), role: .cancel) {}
            Button(lm.translate("Restore", "恢复")) {
                processKiller.restoreKilledApps(using: appLister.apps) { appLister.refreshAppList() }
            }
        } message: {
            Text(lm.translate("Restore all pending apps now?", "确定立即恢复全部待恢复软件？"))
        }
    }

    // MARK: - Helpers

    /// Orange banner shown while the low-battery auto-restore gate is active.
    /// Auto-restore is delayed until charge reaches ≥20%; manual restore is
    /// unaffected (design-spec §3.2).
    private var gateBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text(restoreGateHintText)
                .font(.caption)
            Spacer()
            Text(lm.translate("Manual restore is not affected", "手动恢复不受影响"))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15))
        .foregroundColor(.orange)
        .cornerRadius(6)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    /// SF Symbol name for the given category.
    private func systemIcon(for category: AppCategory) -> String {
        switch category {
        case .application:  return "app"
        case .service:      return "gearshape.2"
        case .launchAgent:  return "bolt"
        case .custom:       return "questionmark"
        }
    }

    /// Localized category label for the given category.
    private func categoryLabel(for category: AppCategory) -> String {
        switch category {
        case .application:  return lm.translate("App", "应用")
        case .service:      return lm.translate("Background Service", "后台服务")
        case .launchAgent:  return lm.translate("Launch Agent", "启动代理")
        case .custom:       return lm.translate("Custom", "自定义")
        }
    }
}
