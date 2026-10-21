//  RefreshIntervalSection.swift
//  BatKill
//
//  Temperature-window refresh interval section (v0.2.3 CHANGE-047).
//
//  Rendered directly below the temperature threshold section of the hardware
//  monitor window. The user picks how many seconds ONE full sweep of all
//  temperature sensors should take (integer 1-9). The value is committed
//  immediately on input — no confirm button, no restart — and persisted, so
//  it takes effect again automatically the next time the window is opened.
//
//  Scope: the value is only consumed by the temperature window's own refresh
//  timer, so closing the window restores the program's default cadence.

import SwiftUI

/// Refresh interval section card, visually mirroring the temperature threshold
/// card (same padding, background, corner radius and icon-title-description-row
/// structure).
struct RefreshIntervalSection: View {
    /// Persisted refresh interval store (1-9 seconds per full sweep).
    @ObservedObject var store: TemperatureRefreshIntervalStore

    /// Localization manager.
    @ObservedObject var lm: LocalizationManager

    /// Text field content while the user is typing.
    @State private var intervalInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundColor(.cyan)
                    .font(.caption)
                Text(lm.translate("Temperature Refresh Interval", "温度刷新间隔"))
                    .font(.subheadline).fontWeight(.medium)
                Spacer()
            }

            Text(lm.translate(
                "Seconds for one full sensor sweep. Applies only while this window is open; the default cadence is restored after closing.",
                "全部传感器刷新一轮所需秒数。仅在本窗口打开期间生效，关闭后恢复程序默认刷新速度。"
            ))
            .font(.caption2)
            .foregroundColor(.secondary)

            HStack(spacing: 6) {
                Text(lm.translate("Cycle:", "间隔:"))
                    .font(.caption)

                // Stepper with clamped range 1-9 seconds, same control pattern
                // as the threshold stepper.
                Stepper(
                    value: Binding(
                        get: { Double(store.seconds) },
                        set: { store.set(seconds: Int($0)) }
                    ),
                    in: 1...9,
                    step: 1
                ) {
                    HStack(spacing: 2) {
                        TextField("1-9", text: $intervalInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 36)
                            .multilineTextAlignment(.center)
                            .onChange(of: intervalInput) { _, newValue in
                                commit(newValue)
                            }
                            .onSubmit { submit() }
                        Text(lm.translate("sec", "秒"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Live "applies right now" indicator, occupying the same slot
                // as the CPU-avg indicator of the threshold section.
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(lm.translate("Active", "生效中"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .onAppear { intervalInput = "\(store.seconds)" }
    }

    /// Commits typed input immediately: keeps digits only, clamps into 1-9,
    /// persists, and re-syncs the field so the displayed value always equals
    /// the value actually driving the refresh timer.
    private func commit(_ raw: String) {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        let value = TemperatureRefreshIntervalStore.clamp(Int(digits) ?? store.seconds)
        store.set(seconds: value)
        let display = "\(value)"
        if intervalInput != display { intervalInput = display }
    }

    /// Enter key: commit, or restore the effective value when the field is empty.
    private func submit() {
        if intervalInput.filter(\.isNumber).isEmpty {
            intervalInput = "\(store.seconds)"
        } else {
            commit(intervalInput)
        }
    }
}
