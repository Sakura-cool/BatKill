import SwiftUI

// MARK: - Popover Content (shown from menu bar)
struct PopoverView: View {
    @ObservedObject var batteryMonitor: BatteryMonitor
    @ObservedObject var appLister: AppLister
    @ObservedObject var processKiller: ProcessKiller
    @ObservedObject var lm: LocalizationManager

    var body: some View {
        VStack(spacing: 12) {
            // ── Header ──
            HStack {
                Image(systemName: batteryMonitor.isOnBattery ? "battery.25" : "powerplug.fill")
                    .font(.title3)
                    .foregroundColor(batteryMonitor.isOnBattery ? .orange : .green)
                Text("BatKill")
                    .font(.headline)
                Spacer()
                badgeView
            }

            // ── Power status bar ──
            HStack {
                Circle()
                    .fill(batteryMonitor.isOnBattery ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(powerText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }

            Divider()

            // ── Badge explanation ──
            VStack(spacing: 4) {
                HStack {
                    Image(systemName: batteryMonitor.isOnBattery ? "arrow.triangle.2.circlepath" : "bolt.slash")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text(explanationText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            // ── Quick actions ──
            HStack(spacing: 8) {
                Button {
                    processKiller.killSelected(appLister.apps)
                } label: {
                    Label(lm.translate("Kill Now", "立即停止"), systemImage: "bolt.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(processKiller.isKilling
                    || !appLister.apps.contains(where: { $0.isSelected && $0.isRunning }))

                Button {
                    (NSApp.delegate as? AppDelegate)?.showSettingsWindow()
                } label: {
                    Label(lm.translate("Settings", "设置"), systemImage: "gearshape")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            // ── Language ──
            Picker("", selection: $lm.currentLanguage) {
                ForEach(Language.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            // ── Status info ──
            Text(statusInfo)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 260)
    }

    // ── Badge in popover ──
    private var badgeView: some View {
        let count = badgeCount
        return Group {
            if count > 0 {
                Text("\(count)")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(batteryMonitor.isOnBattery ? Color.orange : Color.blue)
                    .clipShape(Capsule())
            } else {
                Text("0")
                    .font(.title3).fontWeight(.bold)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
    }

    // ── Computed values ──
    private var badgeCount: Int {
        if batteryMonitor.isOnBattery {
            return processKiller.pendingRestoreCount
        } else {
            return appLister.apps.filter { $0.isSelected && $0.isRunning }.count
        }
    }

    private var powerText: String {
        if batteryMonitor.isOnBattery {
            return lm.translate("Battery — \(Int(batteryMonitor.batteryPercentage))%", "电池 — \(Int(batteryMonitor.batteryPercentage))%")
        }
        return lm.translate("AC Power", "交流电")
    }

    private var explanationText: String {
        if batteryMonitor.isOnBattery {
            return lm.translate(
                "\(badgeCount) app(s) will restore on AC",
                "\(badgeCount) 个应用将在接电时恢复"
            )
        } else {
            return lm.translate(
                "\(badgeCount) app(s) will be killed on battery",
                "\(badgeCount) 个应用将在电池时停止"
            )
        }
    }

    private var statusInfo: String {
        let total = appLister.apps.count
        let running = appLister.apps.filter(\.isRunning).count
        return lm.translate("\(total) apps · \(running) running", "共 \(total) 个 · \(running) 运行中")
    }
}
