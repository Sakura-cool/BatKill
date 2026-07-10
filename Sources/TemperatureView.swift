import SwiftUI

// MARK: - Temperature & Fan Control View
struct TemperatureView: View {
    @ObservedObject var hardwareMonitor: HardwareMonitor
    @ObservedObject var lm: LocalizationManager
    @State private var fanManualModes: [Int: Bool] = [:]
    @State private var fanSpeeds: [Int: Double] = [:]
    @State private var refreshTimer: Timer?

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
                    VStack(spacing: 16) {
                        temperatureSection
                        fanSection
                    }
                    .padding()
                }
            }
        }
        .frame(width: 420, height: 520)
        .onAppear {
            hardwareMonitor.refresh()
            initFanStates()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
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

    // MARK: - Temperature Section

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundColor(.red)
                    .font(.caption)
                Text(lm.translate("Temperatures", "温度"))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }

            if hardwareMonitor.temperatures.isEmpty {
                Text(lm.translate("No temperature sensors found", "未发现温度传感器"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(hardwareMonitor.temperatures) { sensor in
                        HStack {
                            Text(sensor.name)
                                .font(.caption)
                                .frame(width: 100, alignment: .leading)

                            ProgressView(value: normalizedTemp(sensor.temperature), total: 1.0)
                                .tint(tempColor(sensor.temperature))
                                .frame(maxWidth: .infinity)

                            Text(String(format: "%.1f°", sensor.temperature))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(tempColor(sensor.temperature))
                                .frame(width: 50, alignment: .trailing)

                            Circle()
                                .fill(tempColor(sensor.temperature))
                                .frame(width: 6, height: 6)
                        }
                        .padding(.vertical, 4)

                        if sensor.id != hardwareMonitor.temperatures.last?.id {
                            Divider().padding(.leading, 100)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
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
        let speed = fanSpeeds[fan.index] ?? fan.currentSpeed

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
                        hardwareMonitor.setFanMode(fanIndex: fan.index, auto: !newValue)
                        if newValue {
                            fanSpeeds[fan.index] = fan.currentSpeed
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
                            get: { speed },
                            set: { newValue in
                                fanSpeeds[fan.index] = newValue
                                hardwareMonitor.setFanSpeed(fanIndex: fan.index, speed: newValue)
                            }
                        ),
                        in: 0...fan.maxSpeed,
                        step: 50
                    )

                    Image(systemName: "plus")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(String(format: "%d", Int(speed)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 45, alignment: .trailing)
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
            if fanSpeeds[fan.index] == nil {
                fanSpeeds[fan.index] = fan.currentSpeed
            }
        }
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
