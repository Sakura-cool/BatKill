//  AppRowView.swift
//  BatKill
//
//  A single row in the settings app list. Displays the app icon, name,
//  category label, running status indicator, and a system-app badge.
//  The entire row is tappable and acts as a toggle for selection.
//
//  Extracted from ContentView.swift (originally `private struct AppRow`).
//  Access level changed from private to internal so it can live in its
//  own file.

import SwiftUI

// MARK: - App Row View

/// A single row representing one application in the settings list.
/// Shows checkbox, icon, name, category, running indicator, and system badge.
struct AppRowView: View {
    /// The application item to display.
    let app: AppItem

    /// Shared localization manager for translating labels.
    let lm: LocalizationManager

    /// Callback invoked when the user taps the row or checkbox to toggle
    /// this app's selection state.
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // -- Checkbox --
            // Two-way binding that triggers onToggle on change.
            Toggle("", isOn: Binding(
                get: { app.isSelected },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)

            // -- App Icon --
            // Uses the actual app icon for .application category,
            // or a SF Symbol fallback for services/agents/custom.
            icon
                .frame(width: 20, height: 20)

            // -- Name + Category Label --
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .help(app.path)
                Text(categoryLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // -- Running Status Indicator --
            // Green dot + "Running" or gray dot + "Stopped".
            HStack(spacing: 4) {
                Circle()
                    .fill(app.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(app.isRunning
                     ? lm.translate("Running", "运行中")
                     : lm.translate("Stopped", "已停止"))
                    .font(.caption2)
                    .foregroundColor(app.isRunning ? .green : .secondary)
            }

            // -- System Badge --
            // Shown only for system-level apps to warn the user.
            if app.isSystemApp {
                Text(lm.translate("System", "系统"))
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        // Dim non-running system apps to reduce visual noise
        .opacity(app.isSystemApp && !app.isRunning ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    // MARK: - Icon

    /// Returns the app icon. For `.application` category, loads the actual
    /// icon from the app bundle via NSWorkspace. For other categories,
    /// uses a SF Symbol placeholder.
    @ViewBuilder
    private var icon: some View {
        if app.category == .application,
           let nsImg = NSWorkspace.shared.icon(forFile: app.path) as NSImage? {
            Image(nsImage: nsImg)
                .resizable()
        } else {
            Image(systemName: systemIcon)
                .foregroundColor(.secondary)
        }
    }

    /// SF Symbol name mapped from the app's category.
    private var systemIcon: String {
        switch app.category {
        case .application:  return "app"
        case .service:      return "gearshape.2"
        case .launchAgent:  return "bolt"
        case .custom:       return "questionmark"
        }
    }

    // MARK: - Category Label

    /// Localized category description (App / Background Service / Launch Agent / Custom).
    private var categoryLabel: String {
        switch app.category {
        case .application:  return lm.translate("App", "应用")
        case .service:      return lm.translate("Background Service", "后台服务")
        case .launchAgent:  return lm.translate("Launch Agent", "启动代理")
        case .custom:       return lm.translate("Custom", "自定义")
        }
    }
}
