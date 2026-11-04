//  SelectedAppsSheet.swift
//  BatKill
//
//  A sheet that displays all currently-selected applications in a compact
//  list. Each row shows the app icon, name, category, running status, and
//  a remove button (x) to deselect the app directly from this sheet.
//
//  Presented from the bottom bar of SettingsView when the user taps the
//  "Selected (N)" label.
//
//  Extracted from ContentView.swift (originally `private struct SelectedAppsSheet`).
//  Access level changed from private to internal.

import SwiftUI

// MARK: - Selected Apps Sheet

/// A modal sheet listing all applications the user has selected for
/// automatic kill on battery. Provides quick removal via per-row buttons.
struct SelectedAppsSheet: View {
    /// The app list source -- used to read selection state and toggle apps.
    @ObservedObject var appLister: AppLister

    /// Localization manager for translating labels.
    @ObservedObject var lm: LocalizationManager

    /// Environment dismiss action to close the sheet.
    @Environment(\.dismiss) private var dismiss

    // MARK: - Computed

    /// Only apps whose `isSelected` flag is true.
    private var selectedApps: [AppItem] {
        appLister.apps.filter(\.isSelected)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and count
            HStack {
                Text(lm.translate("Selected Apps", "已选程序"))
                    .font(.headline)
                Spacer()
                Text("\(selectedApps.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Content: empty state or scrollable list
            if selectedApps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text(lm.translate("No apps selected", "没有选中的程序"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(selectedApps) { app in
                            HStack(spacing: 8) {
                                // App icon
                                icon(for: app)
                                    .frame(width: 20, height: 20)

                                // Name + category
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(categoryLabel(for: app))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                // Running indicator (green dot)
                                if app.isRunning {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                }

                                // Suspend strategy picker (per-app)
                                // Lets the user choose how BatKill preserves this
                                // app's state on battery and restores it on AC.
                                Menu {
                                    ForEach(SuspendStrategy.allCases, id: \.self) { mode in
                                        Button {
                                            appLister.setSuspendStrategy(mode, for: app)
                                        } label: {
                                            if mode == app.suspendStrategy {
                                                Label(strategyLabel(mode), systemImage: "checkmark")
                                            } else {
                                                Text(strategyLabel(mode))
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: strategyIcon(app.suspendStrategy))
                                        .foregroundColor(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                                .controlSize(.small)
                                .help(strategyHelp(app.suspendStrategy))

                                // Remove (deselect) button
                                Button {
                                    appLister.toggleApp(app)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)

                            if app.id != selectedApps.last?.id {
                                Divider().padding(.leading, 40)
                            }
                        }
                    }
                }
            }

            Divider()

            // Done button
            HStack {
                Spacer()
                Button(lm.translate("Done", "完成")) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding()
        }
        .frame(width: 360, height: 400)
    }

    // MARK: - Helpers

    /// Renders the app icon. Uses the real app icon for `.application` category,
    /// or a SF Symbol placeholder for other categories.
    @ViewBuilder
    private func icon(for app: AppItem) -> some View {
        if app.category == .application,
           let nsImg = NSWorkspace.shared.icon(forFile: app.path) as NSImage? {
            Image(nsImage: nsImg)
                .resizable()
        } else {
            Image(systemName: systemIcon(for: app))
                .foregroundColor(.secondary)
        }
    }

    /// SF Symbol name for the given app's category.
    private func systemIcon(for app: AppItem) -> String {
        switch app.category {
        case .application:  return "app"
        case .service:      return "gearshape.2"
        case .launchAgent:  return "bolt"
        case .custom:       return "questionmark"
        }
    }

    /// Localized category label for the given app.
    private func categoryLabel(for app: AppItem) -> String {
        switch app.category {
        case .application:  return lm.translate("App", "应用")
        case .service:      return lm.translate("Background Service", "后台服务")
        case .launchAgent:  return lm.translate("Launch Agent", "启动代理")
        case .custom:       return lm.translate("Custom", "自定义")
        }
    }

    /// Localized suspend-strategy option label.
    private func strategyLabel(_ mode: SuspendStrategy) -> String {
        switch mode {
        case .suspend:  return lm.translate("Suspend", "挂起")
        case .graceful: return lm.translate("Graceful Quit", "优雅退出")
        case .force:    return lm.translate("Force Quit", "强制退出")
        }
    }

    /// SF Symbol representing the given suspend strategy.
    private func strategyIcon(_ mode: SuspendStrategy) -> String {
        switch mode {
        case .suspend:  return "pause.circle"
        case .graceful: return "arrow.down.circle"
        case .force:    return "bolt.circle"
        }
    }

    /// Tooltip explaining the trade-off of the given suspend strategy.
    private func strategyHelp(_ mode: SuspendStrategy) -> String {
        switch mode {
        case .suspend:  return lm.translate("Suspend: keeps state, uses memory", "挂起：保留状态，占用内存")
        case .graceful: return lm.translate("Graceful quit: app saves its own state", "优雅退出：软件自行保存状态")
        case .force:    return lm.translate("Force quit: most battery-efficient", "强制退出：最省电")
        }
    }
}
