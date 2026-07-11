import SwiftUI
import ServiceManagement

// MARK: - Content View
struct ContentView: View {
    @EnvironmentObject var batteryMonitor: BatteryMonitor
    @EnvironmentObject var appLister: AppLister
    @EnvironmentObject var processKiller: ProcessKiller
    @EnvironmentObject var lm: LocalizationManager
    @EnvironmentObject var versionChecker: VersionChecker
    @EnvironmentObject var updater: Updater
    @EnvironmentObject var hardwareMonitor: HardwareMonitor

    @AppStorage("autoKillEnabled") private var autoKillEnabled = false
    @AppStorage("launchAtLogin")   private var launchAtLogin   = false
    @AppStorage("fanTemperatureThreshold") private var tempThreshold: Double = 98

    @State private var searchText      = ""
    @State private var showOnlyRunning = false
    @State private var showSystemApps  = false
    @State private var showSelectedSheet = false
    @State private var showPendingRestoreSheet = false

    // ──────────────────────────────────────────────
    // MARK: - Filtered Apps
    // ──────────────────────────────────────────────
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
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: batteryMonitor.isOnBattery ? "battery.25" : "powerplug.fill")
                .font(.system(size: 28))
                .foregroundColor(batteryMonitor.isOnBattery ? .orange : .green)
                .symbolEffect(.pulse, value: batteryMonitor.isOnBattery)

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

    private var archLabel: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return String(cString: brand)
    }

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

    private var batterySourceLabel: String {
        batteryMonitor.isOnBattery
            ? lm.translate("Battery", "电池")
            : lm.translate("AC Power", "交流电")
    }

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
    private var filterBar: some View {
        let runningCount = filteredApps.filter(\.isRunning).count
        let systemCount = filteredApps.filter(\.isSystemApp).count
        return HStack(spacing: 8) {
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
                            AppRow(app: app, lm: lm, onToggle: { appLister.toggleApp(app) })
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
    private var bottomBar: some View {
        VStack(spacing: 6) {
            // Top row: actions
            HStack(spacing: 8) {
                Button { appLister.refreshAppList() } label: {
                    Label(lm.translate("Refresh", "刷新"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(appLister.isLoading)

                if appLister.isLoading {
                    ProgressView().scaleEffect(0.5).frame(width: 12)
                }

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

                // Toggle All
                Button { toggleAll() } label: {
                    Text(lm.translate("Toggle All", "切换全选"))
                }
                .buttonStyle(.borderless)
                .font(.caption)

                // Kill button
                Button { processKiller.killSelected(appLister.apps) { appLister.refreshAppList() } } label: {
                    Label(lm.translate("Kill Selected", "停止选中"), systemImage: "bolt.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(processKiller.isKilling
                          || !appLister.apps.contains(where: { $0.isSelected && $0.isRunning }))

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

                // Restore indicator
                if processKiller.isRestoring {
                    ProgressView().scaleEffect(0.5).frame(width: 12)
                }
            }

            // Bottom row: language + auto-start
            HStack(spacing: 8) {
                // Language switcher
                Picker("", selection: $lm.currentLanguage) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                // Launch at login
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
    private func toggleAll() {
        let targets = appLister.apps.filter { !$0.isSystemApp }
        let allSelected = targets.allSatisfy(\.isSelected)
        for app in targets {
            if app.isSelected == allSelected {
                appLister.toggleApp(app)
            }
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("⚠️ Failed to update login item: \(error)")
            launchAtLogin = !enabled // revert
        }
    }
}

// MARK: - App Row
private struct AppRow: View {
    let app: AppItem
    let lm: LocalizationManager
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox
            Toggle("", isOn: Binding(
                get: { app.isSelected },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)

            // Icon
            icon
                .frame(width: 20, height: 20)

            // Name + category
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

            // Running indicator
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

            // System badge
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
        .opacity(app.isSystemApp && !app.isRunning ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

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

    private var systemIcon: String {
        switch app.category {
        case .application:  return "app"
        case .service:      return "gearshape.2"
        case .launchAgent:  return "bolt"
        case .custom:       return "questionmark"
        }
    }

    private var categoryLabel: String {
        switch app.category {
        case .application:  return lm.translate("App", "应用")
        case .service:      return lm.translate("Background Service", "后台服务")
        case .launchAgent:  return lm.translate("Launch Agent", "启动代理")
        case .custom:       return lm.translate("Custom", "自定义")
        }
    }
}

// MARK: - Selected Apps Sheet
private struct SelectedAppsSheet: View {
    @ObservedObject var appLister: AppLister
    @ObservedObject var lm: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    private var selectedApps: [AppItem] {
        appLister.apps.filter(\.isSelected)
    }

    var body: some View {
        VStack(spacing: 0) {
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
                                icon(for: app)
                                    .frame(width: 20, height: 20)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(app.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(categoryLabel(for: app))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if app.isRunning {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 6, height: 6)
                                }

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

    private func systemIcon(for app: AppItem) -> String {
        switch app.category {
        case .application:  return "app"
        case .service:      return "gearshape.2"
        case .launchAgent:  return "bolt"
        case .custom:       return "questionmark"
        }
    }

    private func categoryLabel(for app: AppItem) -> String {
        switch app.category {
        case .application:  return lm.translate("App", "应用")
        case .service:      return lm.translate("Background Service", "后台服务")
        case .launchAgent:  return lm.translate("Launch Agent", "启动代理")
        case .custom:       return lm.translate("Custom", "自定义")
        }
    }
}

// MARK: - Pending Restore Sheet
private struct PendingRestoreSheet: View {
    @ObservedObject var processKiller: ProcessKiller
    @ObservedObject var appLister: AppLister
    @ObservedObject var lm: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    private var pendingApps: [(id: String, name: String, category: AppCategory)] {
        processKiller.pendingRestoreAppIds.compactMap { appId in
            if let app = appLister.apps.first(where: { $0.id == appId }) {
                return (appId, app.name, app.category)
            }
            return (appId, (appId as NSString).lastPathComponent, .custom)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                                Image(systemName: systemIcon(for: item.category))
                                    .foregroundColor(.secondary)
                                    .frame(width: 20, height: 20)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(categoryLabel(for: item.category))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

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

    private func systemIcon(for category: AppCategory) -> String {
        switch category {
        case .application:  return "app"
        case .service:      return "gearshape.2"
        case .launchAgent:  return "bolt"
        case .custom:       return "questionmark"
        }
    }

    private func categoryLabel(for category: AppCategory) -> String {
        switch category {
        case .application:  return lm.translate("App", "应用")
        case .service:      return lm.translate("Background Service", "后台服务")
        case .launchAgent:  return lm.translate("Launch Agent", "启动代理")
        case .custom:       return lm.translate("Custom", "自定义")
        }
    }
}

// MARK: - Binding.onChange helper (macOS 13+ compatible)
extension Binding {
    func onChange(_ handler: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                self.wrappedValue = newValue
                handler(newValue)
            }
        )
    }
}
