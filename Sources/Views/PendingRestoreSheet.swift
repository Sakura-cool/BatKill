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

    // MARK: - Computed

    /// Resolves each pending restore ID into a display tuple of
    /// (id, display name, category). Falls back to the file's
    /// last path component if the app is no longer in the app list.
    private var pendingApps: [(id: String, name: String, category: AppCategory)] {
        processKiller.pendingRestoreAppIds.compactMap { appId in
            if let app = appLister.apps.first(where: { $0.id == appId }) {
                return (appId, app.name, app.category)
            }
            return (appId, (appId as NSString).lastPathComponent, .custom)
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

                                // Name + category label
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(categoryLabel(for: item.category))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                // Delete -- removes from pending list without restoring
                                Button {
                                    withAnimation {
                                        processKiller.removePending(item.id)
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

            Divider()

            // Done button -- refreshes app list and dismisses
            HStack {
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
    }

    // MARK: - Helpers

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
