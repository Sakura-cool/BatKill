//  TemperatureView.swift
//  BatKill
//
//  Full hardware monitoring window displaying CPU temperatures by sensor
//  group, fan speeds with manual/auto control, fan presets, and the
//  temperature threshold that triggers automatic release of fan control
//  to the system.
//
//  Opened via the .showTemperature notification from the settings header
//  or the popover. Hosted in a standalone NSWindow by AppDelegate.
//
//  Layout structure (top to bottom):
//    1. Header            -- thermometer icon, title, sensor/fan count, refresh button
//    2. Unavailable View  -- shown when SMC access fails (missing disk permission)
//    3. Thermal Warning   -- red banner when CPU exceeds the temperature threshold
//    4. Threshold Section -- configurable temperature threshold with stepper
//    5. Temperature Groups -- collapsible P-Core / E-Core / other sensor groups
//    6. Preset Section    -- save/load/delete fan presets
//    7. Fan Control       -- per-fan auto/manual toggle, speed slider, admin auth
//
//  All hardware reads go through HardwareMonitor (SMC). Fan writes require
//  admin privileges, obtained via AuthorizationServices.

import SwiftUI

// MARK: - Temperature & Fan Control View

/// Full-featured hardware monitoring window. Shows CPU temperatures
/// organized by sensor group, fan controls with admin-privileged writes,
/// and a configurable temperature threshold for automatic safety override.
struct TemperatureView: View {

    // MARK: - Observed Objects

    /// Provides live temperature readings, fan info, and SMC write access.
    @ObservedObject var hardwareMonitor: HardwareMonitor

    /// Localization manager for English/Chinese translations.
    @ObservedObject var lm: LocalizationManager

    // MARK: - State Objects

    /// Persistent store for user-defined fan presets (UserDefaults-backed).
    @StateObject private var presetStore = FanPresetStore()

    /// Persistent store for the temperature threshold setting.
    @StateObject private var thresholdStore = TemperatureThresholdStore()

    /// Persistent store for per-fan manual sub-modes (fixed/curve) and
    /// temperature-adaptive fan curves (v0.2.0).
    @StateObject private var curveStore = FanCurveStore()

    // MARK: - Local UI State

    /// Per-fan manual mode flags: true = manual, false = auto.
    @State private var fanManualModes: [Int: Bool] = [:]

    /// Per-fan pending speed values (pending until the user taps "Set Speed").
    @State private var fanPendingSpeeds: [Int: Double] = [:]

    /// Set of expanded temperature category groups in the accordion.
    @State private var expandedCategories: Set<TemperatureCategory> = []

    /// Per-fan last-applied target speed (RPM), used to judge "已生效" when
    /// the read-back converges to it within tolerance (CHANGE-022).
    @State private var fanTargetSpeeds: [Int: Double] = [:]

    /// Per-fan flags indicating admin authorization is needed before writing.
    @State private var fanNeedsAdmin: [Int: Bool] = [:]

    /// Snapshot of fan states saved before thermal throttling, so they
    /// can be restored when the CPU cools back below the threshold.
    @State private var savedFanModes: [Int: Bool] = [:]
    @State private var savedFanSpeeds: [Int: Double] = [:]

    /// Timer that refreshes sensor data every second.
    @State private var refreshTimer: Timer?

    /// Controls the "Save Preset" alert.
    @State private var showingSaveAlert = false

    /// User-entered name for a new preset.
    @State private var newPresetName = ""

    /// The preset targeted for deletion (shows confirmation alert).
    @State private var deleteTarget: FanPreset?

    /// String representation of the threshold for the text field.
    @State private var thresholdInput: String = ""

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if !hardwareMonitor.isAvailable {
                unavailableView
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        if hardwareMonitor.thermalThrottled {
                            thermalWarningBanner
                        }
                        if !hardwareMonitor.fans.isEmpty {
                            thresholdSection
                        }
                        temperatureGroups
                        if !hardwareMonitor.fans.isEmpty {
                            ZStack {
                                VStack(spacing: 12) {
                                    presetSection
                                    fanSection
                                }
                                .blur(radius: hardwareMonitor.fanControlEnabled ? 0 : 8)
                                if !hardwareMonitor.fanControlEnabled {
                                    adminGateOverlay
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 480, height: 600)
        .onAppear {
            // Initialize threshold input field
            thresholdInput = "\(Int(thresholdStore.threshold))"
            hardwareMonitor.refresh()
            // Ensure the built-in "Auto Mode" preset exists
            presetStore.ensureAutoPreset(fanCount: hardwareMonitor.fans.count)
            initFanStates()
            // Apply the currently active preset — only if it does NOT require
            // admin auth. If it does, skip auto-execution so the auth dialog
            // does NOT pop up unrequested on window open; the user can tap
            // the preset manually.
            if let preset = presetStore.activePreset {
                let needsAdmin = preset.fanAutoModes.values.contains(false)
                if !needsAdmin || hardwareMonitor.fanControlEnabled {
                    executePreset(preset)
                }
            }
            hardwareMonitor.onThermalThrottle = {
                guard hardwareMonitor.fanControlEnabled else { return }
                // Save current fan states so they can be restored on cooldown
                savedFanModes = fanManualModes
                savedFanSpeeds = fanPendingSpeeds
                var speeds: [Int: Double] = [:]
                var modes: [Int: Bool] = [:]
                for fan in hardwareMonitor.fans {
                    speeds[fan.index] = 0
                    modes[fan.index] = true
                }
                let auto = FanPreset(id: FanPreset.autoModeID, name: "Auto", fanSpeeds: speeds, fanAutoModes: modes)
                presetStore.update(auto)
                executePreset(auto)
            }
            hardwareMonitor.onThermalCooldown = {
                guard hardwareMonitor.fanControlEnabled else { return }
                guard !savedFanModes.isEmpty else { return }
                // Restore the manual modes and speeds that were active before throttle
                for fan in hardwareMonitor.fans {
                    let idx = fan.index
                    if let wasManual = savedFanModes[idx] {
                        hardwareMonitor.setFanModeWithAdmin(fanIndex: idx, auto: !wasManual) { _ in }
                    }
                    if let speed = savedFanSpeeds[idx] {
                        hardwareMonitor.setFanSpeedWithAdmin(fanIndex: idx, speed: speed) { _ in }
                    }
                }
                // Re-activate the last user preset if it exists and is not auto
                if let active = presetStore.activePreset, active.id != FanPreset.autoModeID {
                    executePreset(active)
                }
            }
            // Start the refresh timer with a battery-aware interval
            refreshTimer = makeRefreshTimer(onBattery: hardwareMonitor.isRunningOnBattery)
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            hardwareMonitor.onThermalThrottle = nil
            hardwareMonitor.onThermalCooldown = nil
        }
        // Dynamically adjust refresh rate when the user plugs/unplugs
        .onReceive(hardwareMonitor.$isRunningOnBattery) { onBattery in
            refreshTimer?.invalidate()
            refreshTimer = makeRefreshTimer(onBattery: onBattery)
        }
    }

    // MARK: - Header

    /// Top bar with thermometer icon, title ("Hardware Monitor"), sensor/fan
    /// count summary, and a manual refresh button.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: 28))
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(lm.translate("Hardware Monitor", "硬件监控"))
                    .font(.title2).fontWeight(.semibold)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()

            Button {
                hardwareMonitor.refresh()
                initFanStates()
            } label: {
                Label(lm.translate("Refresh", "刷新"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    /// Summary of detected sensors and fans.
    private var statusText: String {
        lm.translate("\(hardwareMonitor.temperatures.count) sensors · \(hardwareMonitor.fans.count) fan(s)",
                     "\(hardwareMonitor.temperatures.count) 传感器 · \(hardwareMonitor.fans.count) 风扇")
    }

    // MARK: - Unavailable

    /// Shown when SMC is inaccessible. Instructs the user to grant
    /// Full Disk Access permission to BatKill.
    private var unavailableView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(.secondary)
            Text(lm.translate(
                "Unable to read hardware sensors.\nMake sure BatKill has full disk access.",
                "无法读取硬件传感器。\n请确保 BatKill 拥有完全磁盘访问权限。"
            ))
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Thermal Warning

    /// Red banner displayed when CPU temperature exceeds the configured
    /// threshold. Explains that fan control has been released to the system.
    private var thermalWarningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(lm.translate(
                    "CPU over \(Int(thresholdStore.threshold))°C — fan control released to system",
                    "CPU 超过 \(Int(thresholdStore.threshold))°C — 风扇控制已交还系统"
                ))
                .font(.caption).fontWeight(.medium)
                .foregroundColor(.white)
                Text(lm.translate(
                    "Current: \(String(format: "%.1f", hardwareMonitor.maxCPUTemp))°C",
                    "当前: \(String(format: "%.1f", hardwareMonitor.maxCPUTemp))°C"
                ))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.85))
        .cornerRadius(8)
    }

    // MARK: - Threshold Section

    /// Configurable temperature threshold with a stepper and direct input.
    /// When CPU exceeds this value, fan control is automatically released
    /// to the system for safety.
    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "thermometer")
                    .foregroundColor(.orange)
                    .font(.caption)
                Text(lm.translate("Fan Temperature Threshold", "风扇温度阈值"))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }

            Text(lm.translate(
                "When CPU exceeds this temperature, fan control is released to the system.",
                "当 CPU 超过此温度时，风扇控制将交还系统。"
            ))
            .font(.caption2)
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text(lm.translate("Threshold:", "阈值:"))
                    .font(.caption)

                // Stepper with clamped range 60-120 degrees
                Stepper(
                    value: Binding(
                        get: { thresholdStore.threshold },
                        set: { newVal in
                            let clamped = min(120, max(60, newVal))
                            thresholdStore.threshold = clamped
                            thresholdInput = "\(Int(clamped))"
                        }
                    ),
                    in: 60...120,
                    step: 1
                ) {
                    HStack(spacing: 2) {
                                    TextField("60-120", text: $thresholdInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 36)
                            .multilineTextAlignment(.center)
                            .onSubmit {
                                let digits = thresholdInput.filter(\.isNumber)
                                if let val = Int(digits) {
                                    let clamped = min(120, max(60, val))
                                    thresholdStore.threshold = Double(clamped)
                                }
                                thresholdInput = "\(Int(thresholdStore.threshold))"
                            }
                        Text("°C")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Overheat danger warning
                if hardwareMonitor.thermalThrottled {
                    Text(lm.translate("Overheat Danger!", "过温危险!"))
                        .font(.caption).fontWeight(.bold)
                        .foregroundColor(.red)
                }

                // Live CPU Die temperature indicator
                let cpuTemp = hardwareMonitor.smoothedCPUTemp
                HStack(spacing: 4) {
                    Text(lm.translate("CPU Avg:", "CPU 均温:"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f°C", cpuTemp))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(cpuTemp >= thresholdStore.threshold ? .red : .primary)
                    Circle()
                        .fill(cpuTemp >= thresholdStore.threshold ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Temperature Groups

    /// Collapsible accordion of temperature sensor groups (P-Core, E-Core,
    /// Battery, etc.). Each group shows an average temperature and can be
    /// expanded to reveal individual sensor readings.
    private var temperatureGroups: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = hardwareMonitor.groupedTemperatures
            if groups.isEmpty {
                emptyTempView
            } else {
                ForEach(groups) { group in
                    temperatureGroupRow(group)
                    if group.id != groups.last?.id {
                        Divider().padding(.horizontal, 12)
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    /// Empty-state view when no temperature sensors are detected.
    private var emptyTempView: some View {
        HStack {
            Spacer()
            Text(lm.translate("No temperature sensors found", "未发现温度传感器"))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 16)
            Spacer()
        }
    }

    /// Renders a single temperature group row with expand/collapse toggle.
    private func temperatureGroupRow(_ group: TemperatureGroup) -> some View {
        let isExpanded = expandedCategories.contains(group.category)

        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedCategories.remove(group.category)
                    } else {
                        expandedCategories.insert(group.category)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: group.category.systemImage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)

                    Text(lm.translate(group.category.localizedName.en, group.category.localizedName.zh))
                        .font(.subheadline).fontWeight(.medium)

                    if group.sensors.count > 1 {
                        Text(String(format: "(%d)", group.sensors.count))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Text(String(format: "%.1f°", group.average))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(tempColor(group.average))

                    Circle()
                        .fill(tempColor(group.average))
                        .frame(width: 6, height: 6)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // Expanded sensor detail rows
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.sensors) { sensor in
                        sensorRow(sensor, isLast: sensor.id == group.sensors.last?.id)
                    }
                }
            }
        }
    }

    /// A single sensor row with name, progress bar, temperature, and color dot.
    @ViewBuilder
    private func sensorRow(_ sensor: TemperatureSensor, isLast: Bool) -> some View {
        HStack(spacing: 8) {
            Text(sensor.name).padding(.leading, 16)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)

            ProgressView(value: normalizedTemp(sensor.temperature), total: 1.0)
                .tint(tempColor(sensor.temperature))
                .frame(maxWidth: .infinity)

            Text(String(format: "%.1f°", sensor.temperature))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(tempColor(sensor.temperature))
                .frame(width: 45, alignment: .trailing)

            Circle()
                .fill(tempColor(sensor.temperature))
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)

        if !isLast {
            Divider().padding(.leading, 142)
        }
    }

    // MARK: - Preset Section

    /// Fan preset management section. Lists saved presets with apply/delete
    /// actions, and provides a "Save Current" button to capture the current
    /// fan speeds into a new named preset.
    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan")
                    .foregroundColor(.purple)
                    .font(.caption)
                Text(lm.translate("Fan Presets", "风扇预设"))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }

            if presetStore.presets.isEmpty {
                // No presets yet -- show save button
                HStack {
                    Text(lm.translate("No presets saved", "暂无预设"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        showingSaveAlert = true
                    } label: {
                        Label(lm.translate("Save Current", "保存当前"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            } else {
                // List of saved presets
                ForEach(presetStore.presets) { preset in
                    HStack(spacing: 8) {
                        // Preset selection button (radio-style)
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: presetStore.activePresetID == preset.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(presetStore.activePresetID == preset.id ? .purple : .secondary)
                                    .font(.caption)
                                if preset.isBuiltIn {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                Text(preset.isBuiltIn
                                    ? lm.translate("Auto Mode", "自动模式")
                                    : preset.name)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)

                        // Fan speed summary for this preset
                        let desc = preset.fanSpeeds.keys.sorted().map { idx in
                            if preset.fanAutoModes[idx] == true {
                                return lm.translate("Auto", "自动")
                            }
                            return "\(Int(preset.fanSpeeds[idx] ?? 0))"
                        }.joined(separator: " / ")
                        Text(desc)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)

                        Spacer()

                        // Apply button
                        Button {
                            applyPreset(preset)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)

                        // Delete button (not shown for built-in presets)
                        if !preset.isBuiltIn {
                            Button {
                                deleteTarget = preset
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)

                    if preset.id != presetStore.presets.last?.id {
                        Divider().padding(.leading, 8)
                    }
                }

                // Save Current button at the bottom
                HStack {
                    Spacer()
                    Button {
                        showingSaveAlert = true
                    } label: {
                        Label(lm.translate("Save Current", "保存当前"), systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        // Save Preset sheet -- compact preview with mode + curve thumbnail
        .sheet(isPresented: $showingSaveAlert) {
            savePresetSheet
        }
        // Delete Preset confirmation alert
        .alert(lm.translate("Delete Preset", "删除预设"), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(lm.translate("Delete", "删除"), role: .destructive) {
                if let target = deleteTarget { presetStore.remove(target) }
                deleteTarget = nil
            }
            Button(lm.translate("Cancel", "取消"), role: .cancel) { deleteTarget = nil }
        } message: {
            Text(lm.translate("Delete this preset?", "确定删除此预设？"))
        }
    }

    // MARK: - Admin Gate Overlay

    private var adminGateOverlay: some View {
        AdminGateOverlay(
            notEnabled: !hardwareMonitor.fanControlEnabled,
            lm: lm,
            onAuthorize: {
                FanInstallManager.install { ok in
                    if ok {
                        hardwareMonitor.refreshFanControlEnabled()
                        clearAllNeedsAdmin()
                        bringAppToFront()
                    }
                }
            }
        )
    }

    // MARK: - Fan Section

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan")
                    .foregroundColor(.blue)
                    .font(.caption)
                Text(lm.translate("Fan Control", "风扇控制"))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }

            if hardwareMonitor.fans.isEmpty {
                Text(lm.translate("No fans detected", "未检测到风扇"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(hardwareMonitor.fans) { fan in
                    fanControlRow(fan)
                    if fan.id != hardwareMonitor.fans.last?.id {
                        Divider().padding(.leading, 8)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func fanControlRow(_ fan: FanInfo) -> some View {
        let isManual = fanManualModes[fan.index] ?? false

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fan.name)
                    .font(.caption).fontWeight(.medium)
                    .lineLimit(1)
                    .fixedSize()

                // Mode segmented picker: 自动 | 定速 | 调速.
                Picker("", selection: Binding(
                    get: {
                        if !isManual { return 0 }
                        return curveStore.subMode(for: fan.index) == .curve ? 2 : 1
                    },
                    set: { newValue in
                        let wantsManual = newValue != 0
                                        if wantsManual && hardwareMonitor.thermalThrottled { return }
                        fanManualModes[fan.index] = wantsManual
                        if newValue == 2 {
                            curveStore.setSubMode(.curve, for: fan.index)
                        } else {
                            curveStore.setSubMode(.fixed, for: fan.index)
                        }
                        fanNeedsAdmin[fan.index] = nil

                        // Apply the selected mode immediately (CHANGE-022):
                        // fixed → write the current pending speed once;
                        // curve → write the target for the current temp;
                        // auto → hand control back to the system.
                        switch newValue {
                        case 2:
                            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: false) { _ in self.applyCurveSpeed(for: fan) }
                        case 1:
                            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: false) { ok in
                                if ok { let speed = fanPendingSpeeds[fan.index] ?? fan.currentSpeed; self.writeFixedSpeed(speed, for: fan.index) }
                            }
                        default:
                            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: true) { _ in }
                        }
                    }
                )) {
                    Text(lm.translate("Auto", "自动")).tag(0)
                    Text(lm.translate("Fixed", "定速")).tag(1)
                    Text(lm.translate("Curve", "调速")).tag(2)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)

                Spacer()

                Text(String(format: lm.translate("%d RPM", "%d 转/分"), Int(fan.currentSpeed)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 52, alignment: .trailing)

                FanStatusBadge(isManual: isManual,
                               target: fanTargetSpeeds[fan.index],
                               currentSpeed: fan.currentSpeed,
                               lm: lm)
            }
            .frame(maxWidth: .infinity)

            if isManual && !hardwareMonitor.thermalThrottled {
                if curveStore.subMode(for: fan.index) == .curve {
                    FanCurvePanel(fan: fan, curveStore: curveStore, lm: lm,
                                  onApplySpeed: { _ in self.applyCurveSpeed(for: fan) },
                                  needsAdmin: fanNeedsAdmin[fan.index] == true,
                                  onAuthorize: { self.authorizeCurveFan(for: fan) })
                } else {
                FanFixedSpeedControls(fan: fan, lm: lm, hardwareMonitor: hardwareMonitor,
                                     pendingSpeed: Binding(
                                         get: { fanPendingSpeeds[fan.index] ?? fan.currentSpeed },
                                         set: { fanPendingSpeeds[fan.index] = $0 }),
                                        needsAdmin: fanNeedsAdmin[fan.index] == true,
                                     onSetSpeed: { s in self.writeFixedSpeed(s, for: fan.index) },
                                     onAuthorize: { self.authorizeFixedFan(for: fan.index) })
                }
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Curve Panel

    /// Drives a single fan in "调速" (curve) sub-mode: computes the target speed
    /// from the current CPU temperature and writes it on change. Skips writes
    /// when nothing changed, and hands control to the system when the
    /// temperature exceeds the curve threshold.
    ///
    /// Static because it runs from the refresh timer's escaping closure
    /// (which captures stores weakly, not the SwiftUI view instance).
    private func applyCurveSpeed(for fan: FanInfo) {
        if hardwareMonitor.fanControlEnabled {
            let target = curveStore.targetSpeed(for: fan.index,
                                                fan: fan, maxTemp: hardwareMonitor.maxCPUTemp)
            fanTargetSpeeds[fan.index] = target
            hardwareMonitor.setFanSpeedWithAdmin(fanIndex: fan.index, speed: target) { _ in }
        } else {
            fanNeedsAdmin[fan.index] = true
        }
    }

    private func authorizeCurveFan(for fan: FanInfo) {
        FanInstallManager.install { ok in
            if ok {
                hardwareMonitor.refreshFanControlEnabled()
                clearAllNeedsAdmin()
                applyCurveSpeed(for: fan)
            } else {
            }
        }
    }

    private func writeFixedSpeed(_ speed: Double, for index: Int) {
        if hardwareMonitor.fanControlEnabled {
            fanTargetSpeeds[index] = speed
            hardwareMonitor.setFanSpeedWithAdmin(fanIndex: index, speed: speed) { _ in }
        } else {
            fanNeedsAdmin[index] = true
        }
    }

    /// One successful install clears the flag for every fan.
    private func clearAllNeedsAdmin() {
        fanNeedsAdmin.removeAll()
    }

    private func authorizeFixedFan(for index: Int) {
        FanInstallManager.install { ok in
            if ok {
                hardwareMonitor.refreshFanControlEnabled()
                clearAllNeedsAdmin()
                let speed = fanPendingSpeeds[index] ?? 0
                writeFixedSpeed(speed, for: index)
            } else {
            }
        }
    }

    /// Initializes fan UI state (manual modes and pending speeds) from
    /// current hardware values. Called on appear and on manual refresh.
    private func initFanStates() {
        for fan in hardwareMonitor.fans {
            if fanManualModes[fan.index] == nil { fanManualModes[fan.index] = !fan.isAutoMode }
            if fanPendingSpeeds[fan.index] == nil { fanPendingSpeeds[fan.index] = fan.currentSpeed }
        }
    }

    /// Brings the BatKill app and its Temperature window to the foreground
    /// after an authorization dialog closes. The system may otherwise leave
    /// focus on whichever app was active before the auth dialog appeared.
    private func bringAppToFront() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate()
            NSApp.arrangeInFront(nil)
            (NSApp.windows.first(where: { $0.title == "Temperature" && $0.isVisible })
                ?? NSApp.windows.first(where: { $0.isVisible }))?.makeKeyAndOrderFront(nil)
        }
    }

    /// Applies a fan preset. If the preset requires manual fan modes and
    /// the sudo channel is not installed, runs the one-time install first.
    private func applyPreset(_ preset: FanPreset?) {
        guard let preset = preset else { return }

        if preset.fanAutoModes.values.contains(false) && !hardwareMonitor.fanControlEnabled {
            FanInstallManager.install { ok in
                if ok { hardwareMonitor.refreshFanControlEnabled(); bringAppToFront(); executePreset(preset) }
            }
        } else {
            executePreset(preset)
        }
    }

    /// Writes all fan speeds and modes from the given preset to hardware.
    /// Activates the preset in the store so it is remembered.
    private func executePreset(_ preset: FanPreset) {
        presetStore.activate(preset)
        curveStore.applyPresetSubModes(preset.fanManualSubModes,
                                      curves: preset.fanCurves)
        for (index, isAuto) in preset.fanAutoModes {
            fanManualModes[index] = !isAuto
            if isAuto {
                hardwareMonitor.setFanModeWithAdmin(fanIndex: index, auto: true) { _ in }
            }
        }
        for (index, speed) in preset.fanSpeeds {
            fanPendingSpeeds[index] = speed
            if preset.fanAutoModes[index] != true {
                // Record the applied target so the status badge shows
                // 生效中/已生效 instead of 未设定 (CHANGE-022).
                fanTargetSpeeds[index] = speed
                hardwareMonitor.setFanSpeedWithAdmin(fanIndex: index, speed: speed) { [self] _ in }
            }
        }
    }

    /// Captures the current fan speeds and modes into a new preset with
    /// the user-entered name, saves it to the store, and activates it.
    /// Compact save-preset dialog previewing each fan's mode (auto/fixed/
    /// curve) with fixed speeds and curve thumbnails (v0.2.0 CHANGE-014).
    private var savePresetSheet: some View {
        var subModes: [Int: ManualSubMode] = [:]
        var curves: [Int: FanCurve] = [:]
        var autoModes: [Int: Bool] = [:]
        for fan in hardwareMonitor.fans {
            let mode = curveStore.subMode(for: fan.index)
            subModes[fan.index] = mode
            autoModes[fan.index] = !(fanManualModes[fan.index] ?? false)
            if mode == .curve {
                curves[fan.index] = curveStore.curve(for: fan.index,
                                                     minSpeed: fan.minSpeed, maxSpeed: fan.maxSpeed)
            }
        }
        return SavePresetSheet(
            fans: hardwareMonitor.fans,
            autoModes: autoModes, subModes: subModes,
            pendingSpeeds: fanPendingSpeeds, curves: curves,
            lm: lm,
            onSave: { name in newPresetName = name; saveCurrentAsPreset(); showingSaveAlert = false },
            onCancel: { newPresetName = ""; showingSaveAlert = false }
        )
    }
    private func saveCurrentAsPreset() {
        var speeds: [Int: Double] = [:]
        var autoModes: [Int: Bool] = [:]
        var subModes: [Int: ManualSubMode] = [:]
        var curves: [Int: FanCurve] = [:]
        for fan in hardwareMonitor.fans {
            speeds[fan.index] = fanPendingSpeeds[fan.index] ?? fan.currentSpeed
            let isAuto = !(fanManualModes[fan.index] ?? false)
            autoModes[fan.index] = isAuto
            // Only manual fans persist a sub-mode/curve — auto fans must not
            // carry a stale curve into the preset (CHANGE-016).
            if !isAuto {
                let mode = curveStore.subMode(for: fan.index)
                subModes[fan.index] = mode
                if mode == .curve {
                    curves[fan.index] = curveStore.curve(for: fan.index,
                                                         minSpeed: fan.minSpeed, maxSpeed: fan.maxSpeed)
                }
            }
        }
        let preset = FanPreset(name: newPresetName,
                               fanSpeeds: speeds,
                               fanAutoModes: autoModes,
                               fanManualSubModes: subModes,
                               fanCurves: curves)
        presetStore.add(preset)
        presetStore.activate(preset)
        newPresetName = ""
    }

    /// Normalizes a temperature value to a 0-1 range for the progress bar.
    /// Uses a range of -20 to 100 degrees C.
    private func normalizedTemp(_ temp: Double) -> Double {
        min(max((temp + 20) / 120.0, 0), 1.0)
    }

    private func tempColor(_ temp: Double) -> Color {
        if temp < 50 { return .green }
        if temp < 70 { return .orange }
        return .red
    }

    /// Creates a repeating timer that runs `partialRefresh()` (all sensors)
    /// while the app is active, and `partialRefreshCPUAndGPU()` (CPU/GPU only)
    /// when the app is in background — reducing SMC kernel traps by ~50-70%
    /// when the window is not frontmost. On close the timer is invalidated
    /// so no SMC traffic occurs in the background.
    private func makeRefreshTimer(onBattery: Bool) -> Timer {
        let tick = hardwareRefreshInterval(onBattery: onBattery)
        let timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak hardwareMonitor, weak thresholdStore, weak curveStore] _ in
            guard let hardwareMonitor, let thresholdStore else { return }
            if NSApplication.shared.isActive {
                hardwareMonitor.partialRefresh(threshold: thresholdStore.threshold)
            } else {
                hardwareMonitor.partialRefreshCPUAndGPU(threshold: thresholdStore.threshold)
            }
            curveStore?.lastReadCPUTemp = hardwareMonitor.maxCPUTemp
            if let curveStore, hardwareMonitor.fanControlEnabled {
                for fan in hardwareMonitor.fans where curveStore.subMode(for: fan.index) == .curve {
                    curveStore.driveFan(fan: fan, hardwareMonitor: hardwareMonitor)
                }
            }
        }
        timer.tolerance = tick * 0.1
        return timer
    }
}
