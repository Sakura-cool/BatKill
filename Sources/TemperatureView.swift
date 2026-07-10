import SwiftUI

// MARK: - Temperature & Fan Control View
struct TemperatureView: View {
    @ObservedObject var hardwareMonitor: HardwareMonitor
    @ObservedObject var lm: LocalizationManager
    @StateObject private var presetStore = FanPresetStore()
    @State private var fanManualModes: [Int: Bool] = [:]
    @State private var fanPendingSpeeds: [Int: Double] = [:]
    @State private var expandedCategories: Set<TemperatureCategory> = []
    @State private var fanWriteStatus: [Int: String] = [:]
    @State private var fanNeedsAdmin: [Int: Bool] = [:]
    @State private var refreshTimer: Timer?
    @State private var showingSaveAlert = false
    @State private var newPresetName = ""
    @State private var deleteTarget: FanPreset?

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
                        temperatureGroups
                        presetSection
                        fanSection
                    }
                    .padding()
                }
            }
        }
        .frame(width: 480, height: 600)
        .onAppear {
            hardwareMonitor.refresh()
            initFanStates()
            applyPreset(presetStore.activePreset)
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                hardwareMonitor.refresh()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: - Header

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

    private var statusText: String {
        let tempCount = hardwareMonitor.temperatures.count
        let fanCount = hardwareMonitor.fans.count
        return lm.translate(
            "\(tempCount) sensors · \(fanCount) fan(s)",
            "\(tempCount) 传感器 · \(fanCount) 风扇"
        )
    }

    // MARK: - Unavailable

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

    // MARK: - Temperature Groups

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

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(group.sensors) { sensor in
                        sensorRow(sensor, isLast: sensor.id == group.sensors.last?.id)
                    }
                }
            }
        }
    }

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
                ForEach(presetStore.presets) { preset in
                    HStack(spacing: 8) {
                        Button {
                            applyPreset(preset)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: presetStore.activePresetID == preset.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(presetStore.activePresetID == preset.id ? .purple : .secondary)
                                    .font(.caption)
                                Text(preset.name)
                                    .font(.caption)
                            }
                        }
                        .buttonStyle(.plain)

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

                        Button {
                            applyPreset(preset)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .foregroundColor(.purple)
                        }
                        .buttonStyle(.plain)

                        Button {
                            deleteTarget = preset
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)

                    if preset.id != presetStore.presets.last?.id {
                        Divider().padding(.leading, 8)
                    }
                }

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
        let pendingSpeed = fanPendingSpeeds[fan.index] ?? fan.currentSpeed

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(fan.name)
                    .font(.caption).fontWeight(.medium)
                    .frame(width: 80, alignment: .leading)

                Text(String(format: lm.translate("%d RPM", "%d 转/分"), Int(fan.currentSpeed)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Picker("", selection: Binding(
                    get: { isManual },
                    set: { newValue in
                        fanManualModes[fan.index] = newValue
                        fanWriteStatus[fan.index] = nil
                        fanNeedsAdmin[fan.index] = nil

                        if newValue {
                            fanPendingSpeeds[fan.index] = fan.currentSpeed
                            hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: false) { ok in
                                fanWriteStatus[fan.index] = ok
                                    ? lm.translate("Manual mode set", "已设为手动")
                                    : lm.translate("Failed", "失败")
                            }
                        } else {
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

            if isManual {
                HStack(spacing: 8) {
                    Image(systemName: "minus")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Slider(
                        value: Binding(
                            get: { pendingSpeed },
                            set: { fanPendingSpeeds[fan.index] = $0 }
                        ),
                        in: fan.minSpeed...fan.maxSpeed,
                        step: max(1, fan.maxSpeed / 200)
                    )

                    Image(systemName: "plus")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(String(format: "%d", Int(pendingSpeed)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }

                HStack {
                    Text(String(format: "Min: %d", Int(fan.minSpeed)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "Max: %d", Int(fan.maxSpeed)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        let speed = fanPendingSpeeds[fan.index] ?? fan.currentSpeed
                        if hardwareMonitor.isAdminAuthorized {
                            hardwareMonitor.setFanSpeedWithAdmin(fanIndex: fan.index, speed: speed) { ok in
                                fanWriteStatus[fan.index] = ok
                                    ? lm.translate("Set (Admin)", "已设定(管理员)")
                                    : lm.translate("Failed", "失败")
                            }
                        } else {
                            fanNeedsAdmin[fan.index] = true
                        }
                    } label: {
                        Label(lm.translate("Set Speed", "设定转速"), systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.blue)

                    if fanNeedsAdmin[fan.index] == true {
                        Button {
                            if hardwareMonitor.requestAdminAuth() {
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

    private func applyPreset(_ preset: FanPreset?) {
        guard let preset = preset else { return }

        let needsAdmin = preset.fanAutoModes.values.contains(false)
        if needsAdmin && !hardwareMonitor.isAdminAuthorized {
            if hardwareMonitor.requestAdminAuth() {
                executePreset(preset)
            }
        } else {
            executePreset(preset)
        }
    }

    private func executePreset(_ preset: FanPreset) {
        presetStore.activate(preset)

        for (index, isAuto) in preset.fanAutoModes {
            fanManualModes[index] = !isAuto
            if isAuto {
                hardwareMonitor.setFanModeWithAdmin(fanIndex: index, auto: true) { _ in }
                fanWriteStatus[index] = lm.translate("Auto mode restored", "已恢复自动")
            }
        }

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

    private func normalizedTemp(_ temp: Double) -> Double {
        min(max((temp + 20) / 120.0, 0), 1.0)
    }

    private func tempColor(_ temp: Double) -> Color {
        if temp < 50 { return .green }
        if temp < 70 { return .orange }
        return .red
    }
}
