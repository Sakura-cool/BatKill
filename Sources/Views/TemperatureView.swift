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

    // MARK: - Local UI State

    /// Per-fan manual mode flags: true = manual, false = auto.
    @State private var fanManualModes: [Int: Bool] = [:]

    /// Per-fan pending speed values (pending until the user taps "Set Speed").
    @State private var fanPendingSpeeds: [Int: Double] = [:]

    /// Set of expanded temperature category groups in the accordion.
    @State private var expandedCategories: Set<TemperatureCategory> = []

    /// Per-fan write status messages ("Set (Admin)", "Failed", etc.).
    @State private var fanWriteStatus: [Int: String] = [:]

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
            // Header with title and refresh button
            header
                .padding()
                .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if !hardwareMonitor.isAvailable {
                // SMC access denied or unavailable
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
                            presetSection
                            fanSection
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
            // Fetch initial sensor data
            hardwareMonitor.refresh()
            // Ensure the built-in "Auto Mode" preset exists
            presetStore.ensureAutoPreset(fanCount: hardwareMonitor.fans.count)
            // Initialize fan UI state from current hardware values
            initFanStates()
            // Apply the currently active preset — only if it does NOT require
            // admin auth. If it does, skip auto-execution so the auth dialog
            // does NOT pop up unrequested on window open; the user can tap
            // the preset manually.
            if let preset = presetStore.activePreset {
                let needsAdmin = preset.fanAutoModes.values.contains(false)
                if !needsAdmin || hardwareMonitor.isAdminAuthorized {
                    executePreset(preset)
                }
            }
            // Set up thermal throttle callback to auto-release fans
            hardwareMonitor.onThermalThrottle = {
                guard hardwareMonitor.isAdminAuthorized else { return }
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
            // Set up thermal cooldown callback to restore user settings
            hardwareMonitor.onThermalCooldown = {
                guard hardwareMonitor.isAdminAuthorized else { return }
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
        let tempCount = hardwareMonitor.temperatures.count
        let fanCount = hardwareMonitor.fans.count
        return lm.translate(
            "\(tempCount) sensors · \(fanCount) fan(s)",
            "\(tempCount) 传感器 · \(fanCount) 风扇"
        )
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
                        // Direct text input for the threshold value
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
            Text("  \(sensor.name)")
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
                                        .font(.system(size: 8))
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
        // Save Preset alert -- prompts for a name
        .alert(lm.translate("Save Preset", "保存预设"), isPresented: $showingSaveAlert) {
            TextField(lm.translate("Preset name", "预设名称"), text: $newPresetName)
            Button(lm.translate("Save", "保存")) {
                if !newPresetName.isEmpty { saveCurrentAsPreset() }
            }
            Button(lm.translate("Cancel", "取消"), role: .cancel) { newPresetName = "" }
        } message: {
            let info = hardwareMonitor.fans.map { fan -> String in
                let isAuto = !(fanManualModes[fan.index] ?? false)
                if isAuto {
                    return "\(fan.name): \(lm.translate("Auto", "自动"))"
                }
                let speed = Int(fanPendingSpeeds[fan.index] ?? fan.currentSpeed)
                return "\(fan.name): \(speed) RPM"
            }.joined(separator: "\n")
            Text(info + "\n\n" + lm.translate("Enter a name for this preset", "为此预设输入名称"))
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

    // MARK: - Fan Section

    /// Per-fan control section. Each fan gets an auto/manual segmented
    /// picker, a speed slider (when in manual mode), and a "Set Speed"
    /// button that writes to the SMC (requiring admin authorization).
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

    /// A single fan's control row with auto/manual picker, speed slider,
    /// set button, and admin authorization flow.
    private func fanControlRow(_ fan: FanInfo) -> some View {
        let isManual = fanManualModes[fan.index] ?? false
        let pendingSpeed = fanPendingSpeeds[fan.index] ?? fan.currentSpeed

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Fan name
                Text(fan.name)
                    .font(.caption).fontWeight(.medium)
                    .frame(width: 80, alignment: .leading)

                // Current speed readout
                Text(String(format: lm.translate("%d RPM", "%d 转/分"), Int(fan.currentSpeed)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                // Auto / Manual segmented picker
                Picker("", selection: Binding(
                    get: { isManual },
                    set: { newValue in
                        // Block manual mode if thermally throttled
                        if newValue && hardwareMonitor.thermalThrottled { return }
                        fanManualModes[fan.index] = newValue
                        fanWriteStatus[fan.index] = nil
                        fanNeedsAdmin[fan.index] = nil

                        if newValue {
                            // Switching to manual: initialize pending speed
                            fanPendingSpeeds[fan.index] = fan.currentSpeed
                            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: false) { ok in
                                fanWriteStatus[fan.index] = ok
                                    ? lm.translate("Manual mode set", "已设为手动")
                                    : lm.translate("Failed", "失败")
                            }
                        } else {
                            // Switching to auto: restore system control
                            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: true) { ok in
                                fanWriteStatus[fan.index] = ok
                                    ? lm.translate("Auto mode restored", "已恢复自动")
                                    : lm.translate("Failed", "失败")
                            }
                        }
                    }
                )) {
                    Text(lm.translate("Auto", "自动")).tag(false)
                    Text(lm.translate("Manual", "手动")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            // Manual mode controls (hidden when auto or thermally throttled)
            if isManual && !hardwareMonitor.thermalThrottled {
                // Speed slider with +/- buttons
                HStack(spacing: 8) {
                    Image(systemName: "minus")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { pendingSpeed },
                            set: { fanPendingSpeeds[fan.index] = $0 }
                        ),
                        in: 0...fan.maxSpeed,
                        step: 100
                    )

                    Image(systemName: "plus")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    // Numeric readout of pending speed
                    Text(String(format: "%d", Int(pendingSpeed)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }

                // Min/Max speed labels
                HStack {
                    Text(String(format: "Min: %d", Int(fan.minSpeed)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "Max: %d", Int(fan.maxSpeed)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Action buttons: Set Speed, Authorize Admin, status message
                HStack(spacing: 8) {
                    Button {
                        let speed = fanPendingSpeeds[fan.index] ?? fan.currentSpeed
                        if hardwareMonitor.isAdminAuthorized {
                            // Already authorized -- write speed directly
                            hardwareMonitor.setFanSpeedWithAdmin(fanIndex: fan.index, speed: speed) { ok in
                                fanWriteStatus[fan.index] = ok
                                    ? lm.translate("Set (Admin)", "已设定(管理员)")
                                    : lm.translate("Failed", "失败")
                            }
                        } else {
                            // Need admin -- show authorize button
                            fanNeedsAdmin[fan.index] = true
                        }
                    } label: {
                        Label(lm.translate("Set Speed", "设定转速"), systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)

                    // Admin authorization button (shown after first failed attempt)
                    if fanNeedsAdmin[fan.index] == true {
                        Button {
                            // This is an EXPLICIT user action — reset denied state
                            // so the auth dialog actually appears.
                            HardwareMonitor.resetAuthDenied()
                            if hardwareMonitor.requestAdminAuth() {
                                bringAppToFront()
                                fanNeedsAdmin[fan.index] = nil
                                let speed = fanPendingSpeeds[fan.index] ?? fan.currentSpeed
                                hardwareMonitor.setFanSpeedWithAdmin(fanIndex: fan.index, speed: speed) { ok in
                                    fanWriteStatus[fan.index] = ok
                                        ? lm.translate("Set (Admin)", "已设定(管理员)")
                                        : lm.translate("Admin Failed", "管理员授权失败")
                                }
                            } else {
                                fanWriteStatus[fan.index] = lm.translate("Auth Denied", "授权被拒绝")
                            }
                        } label: {
                            Label(lm.translate("Authorize Admin", "授权管理员"), systemImage: "lock.shield")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.orange)
                    }

                    // Status message after write attempt
                    if let status = fanWriteStatus[fan.index] {
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(fanNeedsAdmin[fan.index] == true ? .red : .green)
                    }

                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    /// Initializes fan UI state (manual modes and pending speeds) from
    /// current hardware values. Called on appear and on manual refresh.
    private func initFanStates() {
        for fan in hardwareMonitor.fans {
            if fanManualModes[fan.index] == nil {
                fanManualModes[fan.index] = !fan.isAutoMode
            }
            if fanPendingSpeeds[fan.index] == nil {
                fanPendingSpeeds[fan.index] = fan.currentSpeed
            }
        }
    }

    /// Brings the BatKill app and its Temperature window to the foreground
    /// after an authorization dialog closes. The system may otherwise leave
    /// focus on whichever app was active before the auth dialog appeared.
    private func bringAppToFront() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate()
            NSApp.arrangeInFront(nil)
            if let window = NSApp.windows.first(where: { $0.title == "Temperature" && $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            } else if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Applies a fan preset. If the preset requires manual fan modes and
    /// admin is not yet authorized, requests authorization first.
    private func applyPreset(_ preset: FanPreset?) {
        guard let preset = preset else { return }

        let needsAdmin = preset.fanAutoModes.values.contains(false)
        if needsAdmin && !hardwareMonitor.isAdminAuthorized {
            // User explicitly tapped a preset — reset denied flag so the
            // auth dialog appears when they're ready to try again.
            HardwareMonitor.resetAuthDenied()
            if hardwareMonitor.requestAdminAuth() {
                bringAppToFront()
                executePreset(preset)
            }
        } else {
            executePreset(preset)
        }
    }

    /// Writes all fan speeds and modes from the given preset to hardware.
    /// Activates the preset in the store so it is remembered.
    private func executePreset(_ preset: FanPreset) {
        presetStore.activate(preset)

        // Apply auto/manual modes
        for (index, isAuto) in preset.fanAutoModes {
            fanManualModes[index] = !isAuto
            if isAuto {
                hardwareMonitor.setFanModeWithAdmin(fanIndex: index, auto: true) { _ in }
                fanWriteStatus[index] = lm.translate("Auto mode restored", "已恢复自动")
            }
        }

        // Apply speeds for manual-mode fans
        for (index, speed) in preset.fanSpeeds {
            fanPendingSpeeds[index] = speed
            if preset.fanAutoModes[index] != true {
                hardwareMonitor.setFanSpeedWithAdmin(fanIndex: index, speed: speed) { [self] ok in
                    fanWriteStatus[index] = ok
                        ? lm.translate("Preset applied", "已应用预设")
                        : lm.translate("Failed", "失败")
                }
            }
        }
    }

    /// Captures the current fan speeds and modes into a new preset with
    /// the user-entered name, saves it to the store, and activates it.
    private func saveCurrentAsPreset() {
        var speeds: [Int: Double] = [:]
        var autoModes: [Int: Bool] = [:]
        for fan in hardwareMonitor.fans {
            speeds[fan.index] = fanPendingSpeeds[fan.index] ?? fan.currentSpeed
            autoModes[fan.index] = !(fanManualModes[fan.index] ?? false)
        }
        let preset = FanPreset(name: newPresetName, fanSpeeds: speeds, fanAutoModes: autoModes)
        presetStore.add(preset)
        presetStore.activate(preset)
        newPresetName = ""
    }

    /// Normalizes a temperature value to a 0-1 range for the progress bar.
    /// Uses a range of -20 to 100 degrees C.
    private func normalizedTemp(_ temp: Double) -> Double {
        min(max((temp + 20) / 120.0, 0), 1.0)
    }

    /// Returns a color indicating the severity of a temperature reading.
    /// Green (< 50), Orange (50-70), Red (>= 70).
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
        let timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak hardwareMonitor, weak thresholdStore] _ in
            guard let hardwareMonitor, let thresholdStore else { return }
            if NSApplication.shared.isActive {
                hardwareMonitor.partialRefresh(threshold: thresholdStore.threshold)
            } else {
                hardwareMonitor.partialRefreshCPUAndGPU(threshold: thresholdStore.threshold)
            }
        }
        timer.tolerance = tick * 0.1
        return timer
    }
}

// MARK: - Battery-Aware Refresh Interval

/// Returns the hardware sensor refresh interval based on the current
/// architecture and power source. Polls less frequently on battery
/// to reduce SMC/IOKit overhead.
///
/// Per-tick interval for staggered SMC reads. Each tick reads ONE sensor
/// key. With ~15-20 keys, a full refresh cycle takes interval × keyCount
/// seconds (~6-8s on AC, ~10-14s on battery).
///
/// |              | Apple Silicon | Intel x86_64 |
/// |--------------|--------------|--------------|
/// | AC Power     |  1.0s        |  1.2s        |
/// | Battery      |  2.0s        |  2.5s        |
func hardwareRefreshInterval(onBattery: Bool) -> TimeInterval {
    #if arch(x86_64)
    return onBattery ? 2.5 : 1.2
    #else
    return onBattery ? 2.0 : 1.0
    #endif
}

func batteryPollInterval(onBattery: Bool) -> TimeInterval {
    onBattery ? 15.0 : 5.0
}
