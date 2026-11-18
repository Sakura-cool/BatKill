//  SettingsView.swift
//  BatKill
//
//  Main settings panel displayed when the user opens the Settings window
//  from the menu bar. Shows all discovered applications in a filterable,
//  searchable list with checkboxes for selecting which apps to kill on
//  battery power.
//
//  Layout structure (top to bottom):
//    1. Header     -- power icon, temp badge, hardware info, power status, status badge
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
    /// The app delegate, which exposes the power contact-issue dialog state
    /// (`showContactIssueDialog` + `resolveContactIssue(_:)`, design-spec §6.2).
    @EnvironmentObject var appDelegate: AppDelegate

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
    /// Controls presentation of the "Bulk Quick Restore" confirmation alert.
    @State private var showBulkRestoreConfirm = false
    /// Timer that keeps the header temperature badge updating while the
    /// settings window is open, even if the Temperature window never opened.
    @State private var hardwareRefreshTimer: Timer?

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
        .onAppear { startHardwareRefresh() }
        .onDisappear { stopHardwareRefresh() }
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
        .alert(
            lm.translate("Power contact unstable", "电源接触不良"),
            isPresented: Binding(
                get: { appDelegate.showContactIssueDialog },
                set: { newValue in
                    if !newValue {
                        // Passive dismissal (Esc / click-away) with no explicit
                        // button choice defaults to the safe action: pause restore.
                        if appDelegate.showContactIssueDialog {
                            appDelegate.resolveContactIssue(.pause)
                        } else {
                            appDelegate.showContactIssueDialog = false
                        }
                    }
                }
            )
        ) {
            // Choices follow the FINAL power state (真机反馈): on battery there is
            // no restore to pause or continue, so only ignore/stop are offered.
            if appDelegate.contactIssueOnBattery {
                Button(ContactIssuePrompt.title(.ignore, onBattery: true)) {
                    appDelegate.resolveContactIssue(.ignore)
                }
                .keyboardShortcut(.defaultAction)
                Button(ContactIssuePrompt.title(.stop, onBattery: true), role: .destructive) {
                    appDelegate.resolveContactIssue(.stop)
                }
            } else {
                // Pause restore -- safe default (Enter).
                Button(lm.translate("Pause restore", "暂停恢复")) {
                    appDelegate.resolveContactIssue(.pause)
                }
                .keyboardShortcut(.defaultAction)
                // Ignore the unstable contact and continue the restore sequence.
                Button(lm.translate("Ignore & continue restore", "继续忽略异常，继续恢复")) {
                    appDelegate.resolveContactIssue(.ignore)
                }
                // Stop -- cancel restore, keep apps stopped, keep pending list.
                Button(lm.translate("Stop", "停止"), role: .destructive) {
                    appDelegate.resolveContactIssue(.stop)
                }
            }
        } message: {
            Text(appDelegate.contactIssueOnBattery
                ? ContactIssuePrompt.informative(onBattery: true)
                : lm.translate(
                    "Repeated power switching detected — possible loose contact",
                    "检测到电源反复切换，可能接触不良"))
        }
    }

    /// Refreshes sensor data on appear and keeps the temperature badge live
    /// while the settings window is open. Without this the badge stays at 0
    /// until the temperature window is opened once, because `refresh()` is
    /// otherwise only triggered by `TemperatureView.onAppear`.
    private func startHardwareRefresh() {
        hardwareMonitor.refresh()
        hardwareRefreshTimer?.invalidate()
        hardwareRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            hardwareMonitor.partialRefreshCPUAndGPU()
        }
    }

    private func stopHardwareRefresh() {
        hardwareRefreshTimer?.invalidate()
        hardwareRefreshTimer = nil
    }

    // ──────────────────────────────────────────────
    // MARK: - Header
    // ──────────────────────────────────────────────

    /// Top section showing temperature badge, hardware info, and a battery/AC status pill.
    private var header: some View {
        HStack(spacing: 12) {
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
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
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
            .accessibilityLabel(lm.translate("Temperature & Fan Control", "温度与风扇控制"))
            .help(lm.translate("Temperature & Fan Control", "温度与风扇控制"))

            // Hardware info as primary line + power status (app name + version moved to title bar)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(archLabel)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(hardwareInfo)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
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

        return lm.translate("RAM \(ramGB)GB · ROM \(totalGB)GB", "内存 \(ramGB)GB · 磁盘 \(totalGB)GB")
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
        VStack(spacing: 8) {
            // ── List-management row: refresh, counts, toggle-all. ──
            // Kept on its own light row so the primary kill/restore actions
            // below are not crowded out by list-level controls (design-spec §1.2).
            HStack(spacing: 6) {
                // Refresh app list
                Button { appLister.refreshAppList() } label: {
                    HStack(spacing: 4) {
                        Group {
                            if appLister.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .frame(width: 14, alignment: .center)
                        Text(lm.translate("Refresh", "刷新"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(appLister.isLoading)

                // Selected / Pending counts with sheet triggers
                let selectedCount = appLister.apps.filter(\.isSelected).count
                let pendingCount = processKiller.pendingRestoreCount
                HStack(spacing: 2) {
                    Button { showSelectedSheet = true } label: {
                        Text("\(lm.translate("Selected", "已选")) \(selectedCount)")
                            .font(.caption2).foregroundColor(selectedCount > 0 ? .blue : .secondary)
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
            }

            // ── Primary action row: kill + restore (sequential / bulk). ──
            HStack(spacing: 6) {
                // Kill Selected -- terminates all selected running apps
                Button { processKiller.killSelected(appLister.apps) { appLister.refreshAppList() } } label: {
                    Label(lm.translate("Kill Selected", "停止选中"), systemImage: "bolt.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(processKiller.isKilling
                          || !appLister.apps.contains(where: { $0.isSelected && $0.isRunning }))

                // Restore Sequentially -- serial, ordered restore of all pending
                // apps (safe default path, no confirmation needed per AC-606).
                Button {
                    processKiller.restoreSequential(using: appLister.apps) { appLister.refreshAppList() }
                } label: {
                    Label(lm.translate("Restore Sequentially", "依次恢复"), systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.green)
                .disabled(processKiller.isRestoring
                          || processKiller.pendingRestoreCount == 0)
                .help(lm.translate(
                    "Restore pending apps one at a time",
                    "依次恢复待恢复软件（逐个有序）"
                ))

                // Bulk Quick Restore -- restore all pending apps at once. Requires
                // confirmation because launching many apps may cause a brief stutter.
                Button { showBulkRestoreConfirm = true } label: {
                    Label(lm.translate("Bulk Quick Restore", "批量快速恢复"), systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
                .disabled(processKiller.isRestoring
                          || processKiller.pendingRestoreCount == 0)
                .help(lm.translate(
                    "Restore all pending apps at once (may stutter)",
                    "一次性恢复全部待恢复软件（可能造成卡顿）"
                ))

                Spacer()

                // Kill in-flight indicator. Restore in-flight is surfaced by the
                // full-width progress row below (design-spec §6.1 mutual exclusion).
                if processKiller.isKilling {
                    ProgressView().controlSize(.small).frame(width: 14)
                }
            }

            // ── Status row: restore progress (during a restore) or the compact
            // low-battery gate hint (auto-restore delayed, not restoring). ──
            if processKiller.isRestoring {
                RestoreProgressRow(processKiller: processKiller, lm: lm)
            } else if isRestoreGateDelayed && processKiller.pendingRestoreCount > 0 {
                gateHintRow
            }

            // Bottom row: language + auto-start + update
            HStack(spacing: 8) {
                // Language segmented picker (fixed-size pure-SwiftUI control
                // so it renders identically on arm64 and x86_64)
                LanguagePicker(selection: $lm.currentLanguage)

                Spacer()

                // Launch at login toggle
                Toggle(isOn: $launchAtLogin.onChange(updateLaunchAtLogin)) {
                    Text(lm.translate("Auto-start", "开机自启"))
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .frame(height: 15)
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
                    ProgressView().controlSize(.small).frame(width: 12)
                }
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Actions
    // ──────────────────────────────────────────────

    /// True when the low-battery auto-restore gate is active (auto-restore
    /// delayed below 20% while on AC). Drives the secondary gate hint; the
    /// manual restore buttons remain enabled regardless (AC-601/AC-608).
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

    /// Compact low-battery gate hint shown beneath the action rows while
    /// auto-restore is delayed (design-spec §3.2 secondary position). Given
    /// its own full-width row so it never crowds the kill/restore buttons;
    /// the manual restore buttons remain enabled regardless (AC-601/AC-608),
    /// so the hint only reports the auto-restore hold-up (via `.help`).
    private var gateHintRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(restoreGateHintText)
            Spacer()
        }
        .font(.caption2)
        .foregroundColor(.orange)
        .help(lm.translate("Manual restore is not affected", "手动恢复不受影响"))
    }

    /// Toggles selection for all non-system apps. If all are currently
    /// selected, deselects all. Otherwise, selects all.
    private func toggleAll() {
        let targets = filteredApps.filter { !$0.isSystemApp }
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
            logger("更新登录项失败: \(error)")
            launchAtLogin = !enabled // revert
        }
    }
}

// Binding.onChange helper is defined in Core/Extensions.swift

// MARK: - Restore Progress Row

/// Full-width linear progress row shared by SettingsView and PendingRestoreSheet.
/// Reads progress directly from ProcessKiller's @Published fields, so both
/// surfaces share the same restore-progress source (design-spec §2.2 / §4.2).
struct RestoreProgressRow: View {
    /// The process killer publishing restore progress.
    @ObservedObject var processKiller: ProcessKiller
    /// Localization manager for translating labels.
    @ObservedObject var lm: LocalizationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(
                value: Double(processKiller.restoreDone),
                total: Double(max(processKiller.restoreTotal, 1))
            )
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(.green)

            Text(progressCaption)
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Progress caption driven by `restorePhase`. Batch mode never settles in
    /// `.waiting`, so the interval segment naturally hides for bulk restores.
    private var progressCaption: String {
        let restored = lm.translate(
            "Restored %d / %d",
            "已恢复 %d / %d",
            processKiller.restoreDone,
            processKiller.restoreTotal
        )
        switch processKiller.restorePhase {
        case .waiting(let intervalSec):
            let name = processKiller.nextRestoreName ?? "—"
            let next = lm.translate("Next: %@", "下一个：%@", name)
            let interval = lm.translate("Interval %ds", "间隔 %ds", Int(intervalSec))
            return "\(restored) · \(next) · \(interval)"
        case .restoring(let name):
            let restoring = lm.translate("Restoring %@…", "正在恢复 %@…", name)
            return "\(restored) · \(restoring)"
        case .idle:
            return restored
        }
    }
}
