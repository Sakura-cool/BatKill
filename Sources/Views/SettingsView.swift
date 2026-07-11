//  SettingsView.swift
//  BatKill
//
//  Main settings panel displayed when the user opens the Settings window
//  from the menu bar. Shows all discovered applications in a filterable,
//  searchable list with checkboxes for selecting which apps to kill on
//  battery power.
//
//  Layout structure (top to bottom):
//    1. Header     -- power icon, app name, version, hardware info, status badge
//    2. Auto-Kill  -- toggle switch for automatic kill on battery
//    3. Filter Bar -- search field + running/system toggles
//    4. App List   -- scrollable list of AppRowView items
//    5. Bottom Bar -- refresh, selected count, toggle-all, kill/restore, language, auto-start
//
//  This view was previously named `ContentView` in the flat Sources/ directory.
//  The type was renamed to `SettingsView` to better reflect its purpose.

import SwiftUI
import ServiceManagement

// MARK: - Settings View (formerly ContentView)

/// The primary settings panel of BatKill. Requires all 7 environment objects
/// to function: BatteryMonitor, AppLister, ProcessKiller, LocalizationManager,
/// VersionChecker, Updater, and HardwareMonitor.
struct SettingsView: View {

    // MARK: - Environment Objects

    @EnvironmentObject var batteryMonitor: BatteryMonitor
    @EnvironmentObject var appLister: AppLister
    @EnvironmentObject var processKiller: ProcessKiller
    @EnvironmentObject var lm: LocalizationManager
    @EnvironmentObject var versionChecker: VersionChecker
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var hardwareMonitor: HardwareMonitor

    // MARK: - Persisted Preferences

    /// Whether automatic kill-on-battery is enabled.
    @AppStorage("autoKillEnabled") private var autoKillEnabled = false
    /// Whether the app launches automatically at login.
    @AppStorage("launchAtLogin")   private var launchAtLogin   = false
    /// CPU temperature threshold (degrees C) at which fan control reverts to system.
    @AppStorage("fanTemperatureThreshold") private var tempThreshold: Double = 98

    // MARK: - Local UI State

    /// Text entered in the search field to filter the app list by name.
    @State private var searchText      = ""
    /// When true, only currently-running apps are shown.
    @State private var showOnlyRunning = false
    /// When true, system-level apps are included in the list.
    @State private var showSystemApps  = false
    /// Controls presentation of the "Selected Apps" sheet.
    @State private var showSelectedSheet = false
    /// Controls presentation of the "Pending Restore" sheet.
    @State private var showPendingRestoreSheet = false

    // ──────────────────────────────────────────────
    // MARK: - Filtered Apps
    // ──────────────────────────────────────────────

    /// The app list after applying the current search text and filter toggles.
    private var filteredApps: [AppItem] {
        var result = appLister.apps

        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        if showOnlyRunning {
            result = result.filter { $0.isRunning }
        }
        if !showSystemApps {
            result = result.filter { !$0.isSystemApp }
        }
        return result
    }

    // ──────────────────────────────────────────────
    // MARK: - Body
    // ──────────────────────────────────────────────

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            Divider()

            autoKillBar
                .padding(.horizontal)
                .padding(.vertical, 6)
            Divider()

            filterBar
                .padding(.horizontal)
                .padding(.vertical, 6)

            appList

            Divider()
            bottomBar
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .frame(width: 500, height: 640)
    }

    // ──────────────────────────────────────────────
    // MARK: - Header
    // ──────────────────────────────────────────────

    /// Top section showing power status icon, temperature badge, app name,
    /// version, hardware info, and a battery/AC status pill.
    private var header: some View {
        HStack(spacing: 12) {
            // Power state icon with pulse animation
            Image(systemName: batteryMonitor.isOnBattery ? "battery.25" : "powerplug.fill")
                .font(.system(size: 28))
                .foregroundColor(batteryMonitor.isOnBattery ? .orange : .green)
                .symbolEffect(.pulse, value: batteryMonitor.isOnBattery)

            // Temperature badge -- tapping opens the Temperature window
            Button {
                NotificationCenter.default.post(name: .showTemperature, object: nil)
            } label: {
                ZStack {
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 16))
                        .foregroundColor(.red)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(6)

                    Text(String(format: "%d", Int(hardwareMonitor.maxCPUTemp)))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(hardwareMonitor.maxCPUTemp >= tempThreshold
                                      ? Color.red
                                      : Color.orange)
                        )
                        .offset(x: 6, y: 10)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help(lm.translate("Temperature & Fan Control", "温度与风扇控制"))

            // App name, version, and hardware info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("BatKill").font(.title2).fontWeight(.semibold)
                    Text("\(versionChecker.currentVersion)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                Text("\(archLabel) · \(hardwareInfo)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(powerStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            statusBadge
        }
    }

    /// Displays the current power source and battery percentage.
    private var powerStatusText: String {
        if batteryMonitor.isOnBattery {
            lm.translate(
                "\(batteryMonitor.powerSource) — \(Int(batteryMonitor.batteryPercentage))% remaining",
                "\(batterySourceLabel) — 剩余 \(Int(batteryMonitor.batteryPercentage))%"
            )
        } else {
            batterySourceLabel
        }
    }

    /// Retrieves the CPU brand string via sysctl (e.g. "Apple M2 Pro").
    private var archLabel: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return String(cString: brand)
    }

    /// Returns a string summarizing RAM and disk (ROM) sizes.
    private var hardwareInfo: String {
        var memSize: UInt64 = 0
        var memLen = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &memLen, nil, 0)
        let ramGB = memSize / 1024 / 1024 / 1024

        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let totalSize = (attrs?[.systemSize] as? UInt64) ?? 0
        let totalGB = totalSize / 1000 / 1000 / 1000

        return "RAM \(ramGB)GB · ROM \(totalGB)GB"
    }

    /// Localized label for the current power source ("Battery" / "AC Power").
    private var batterySourceLabel: String {
        batteryMonitor.isOnBattery
            ? lm.translate("Battery", "电池")
            : lm.translate("AC Power", "交流电")
    }

    /// Pill-shaped badge showing battery or AC status with a colored background.
    private var statusBadge: some View {
        Group {
            if batteryMonitor.isOnBattery {
                Label(lm.translate("Battery", "电池"), systemImage: "battery.25")
                    .font(.caption).foregroundColor(.orange)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
            } else {
                Label(lm.translate("AC Power", "交流电"), systemImage: "powerplug.fill")
                    .font(.caption).foregroundColor(.green)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(8)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Auto-Kill Toggle
    // ──────────────────────────────────────────────

    /// Toggle bar for enabling/disabling automatic kill on battery power.
    private var autoKillBar: some View {
        HStack {
            Image(systemName: autoKillEnabled ? "shield.fill" : "shield.slash")
                .foregroundColor(autoKillEnabled ? .blue : .secondary)
                .font(.title3)
            Text(lm.translate("Auto-kill on battery", "使用电池时自动停止"))
                .font(.subheadline).fontWeight(.medium)
            Spacer()
            Toggle("", isOn: $autoKillEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 4)
    }

    // ──────────────────────────────────────────────
    // MARK: - Filter Bar
    // ──────────────────────────────────────────────

    /// Search field and filter toggles (running only, system apps).
    private var filterBar: some View {
        let runningCount = filteredApps.filter(\.isRunning).count
        let systemCount = filteredApps.filter(\.isSystemApp).count
        return HStack(spacing: 8) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("", text: $searchText, prompt: Text(lm.translate("Search apps…", "搜索应用…")))
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)

            Toggle("\(lm.translate("Running", "运行中")) \(runningCount)", isOn: $showOnlyRunning)
                .toggleStyle(.checkbox).controlSize(.small).font(.caption)
            Toggle("\(lm.translate("System", "系统")) \(systemCount)", isOn: $showSystemApps)
                .toggleStyle(.checkbox).controlSize(.small).font(.caption)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - App List
    // ──────────────────────────────────────────────

    /// Scrollable list of apps. Shows a loading spinner while scanning,
    /// an empty-state view when no apps match filters, or a LazyVStack
    /// of AppRowView items.
    private var appList: some View {
        Group {
            if appLister.isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text(lm.translate("Scanning installed apps…", "正在扫描应用…"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            } else if filteredApps.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.title).foregroundColor(.secondary)
                    Text(lm.translate("No apps match your filter", "没有匹配的应用"))
                        .font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredApps) { app in
                            AppRowView(app: app, lm: lm, onToggle: { appLister.toggleApp(app) })
                            if app.id != filteredApps.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // ──────────────────────────────────────────────
    // MARK: - Bottom Bar
    // ──────────────────────────────────────────────

    /// Bottom toolbar containing refresh, selected count, pending restore,
    /// toggle-all, kill/restore buttons, language picker, auto-start toggle,
    /// and update notification.
    private var bottomBar: some View {
        VStack(spacing: 6) {
            // Top row: actions
            HStack(spacing: 8) {
                // Refresh app list
                Button { appLister.refreshAppList() } label: {
                    Label(lm.translate("Refresh", "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(appLister.isLoading)

                if appLister.isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12)
                }

                // Selected / Pending counts with sheet triggers
                let selectedCount = appLister.apps.filter(\.isSelected).count
                let pendingCount = processKiller.pendingRestoreCount
                HStack(spacing: 2) {
                    Button { showSelectedSheet = true } label: {
                        Text("\(lm.translate("Selected", "已选")) \(selectedCount)")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedCount == 0)
                    .sheet(isPresented: $showSelectedSheet) {
                        SelectedAppsSheet(appLister: appLister, lm: lm)
                    }

                    if pendingCount > 0 {
                        Text("·")
                            .font(.caption2).foregroundColor(.secondary)
                        Button { showPendingRestoreSheet = true } label: {
                            Text("\(pendingCount) \(lm.translate("pending", "待恢复"))")
                                .font(.caption2).foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showPendingRestoreSheet) {
                            PendingRestoreSheet(processKiller: processKiller, appLister: appLister, lm: lm)
                        }
                    }
                }

                Spacer()

                // Toggle All (select/deselect all non-system apps)
                Button { toggleAll() } label: {
                    Text(lm.translate("Toggle All", "切换全选"))
                }
                .buttonStyle(.borderless)
                .font(.caption)

                // Kill Selected -- terminates all selected running apps
                Button { processKiller.killSelected(appLister.apps) { appLister.refreshAppList() } } label: {
                    Label(lm.translate("Kill Selected", "停止选中"), systemImage: "bolt.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(processKiller.isKilling
                          || !appLister.apps.contains(where: { $0.isSelected && $0.isRunning }))

                // Restore Selected -- restarts previously killed apps
                Button { processKiller.restoreSelected(appLister.apps) { appLister.refreshAppList() } } label: {
                    Label(lm.translate("Restore Selected", "恢复选中"), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(processKiller.isRestoring
                          || processKiller.pendingRestoreCount == 0)

                if processKiller.isKilling {
                    ProgressView().scaleEffect(0.5).frame(width: 12)
                }

                if processKiller.isRestoring {
                    ProgressView().scaleEffect(0.5).frame(width: 12)
                }
            }

            // Bottom row: language + auto-start + update
            HStack(spacing: 8) {
                // Language segmented picker
                Picker("", selection: $lm.currentLanguage) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                // Launch at login toggle
                Toggle(isOn: $launchAtLogin.onChange(updateLaunchAtLogin)) {
                    Text(lm.translate("Auto-start", "开机自启"))
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help(lm.translate(
                    "Launch BatKill automatically when you log in",
                    "登录时自动启动 BatKill"
                ))

                // Update button / progress
                if versionChecker.hasUpdate, let ver = versionChecker.latestVersion {
                    if updater.isDownloading {
                        ProgressView(value: updater.downloadProgress)
                            .frame(width: 60)
                    } else {
                        Button {
                            updater.downloadAndInstall()
                        } label: {
                            Label(
                                lm.translate("Update to v\(ver)", "更新到 v\(ver)"),
                                systemImage: "arrow.down.circle"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                } else if versionChecker.isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12)
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    /// Toggles selection for all non-system apps. If all are currently
    /// selected, deselects all. Otherwise, selects all.
    private func toggleAll() {
        let targets = appLister.apps.filter { !$0.isSystemApp }
        let allSelected = targets.allSatisfy(\.isSelected)
        for app in targets {
            if app.isSelected == allSelected {
                appLister.toggleApp(app)
            }
        }
    }

    /// Registers or unregisters the app as a login item via SMAppService.
    /// Reverts the toggle if the operation fails.
    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update login item: \(error)")
            launchAtLogin = !enabled // revert
        }
    }
}

// Binding.onChange helper is defined in Core/Extensions.swift
