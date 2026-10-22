//  RefreshIntervalSection.swift
//  BatKill
//
//  Temperature-window refresh interval section (v0.2.3 CHANGE-047).
//
//  Rendered directly below the temperature threshold section of the hardware
//  monitor window. The user picks how many seconds ONE full sweep of all
//  temperature sensors should take (integer 1-9). The value is committed
//  immediately on input — no restart — and persisted, so it takes effect again
//  automatically the next time the window is opened.
//
//  CHANGE-049: text scaled to ~2/3 of the previous sizes and the paddings
//  tightened so this card and the threshold card above it read as one tight
//  settings pair; an explicit "Apply" button sits flush right of the stepper
//  (it re-commits the current field content, which is already live-applied).
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundColor(.cyan)
                    .font(.system(size: 10))
                Text(lm.translate("Temperature Refresh Interval", "温度刷新间隔"))
                    .font(.system(size: 10, weight: .medium))
                Spacer()
            }

            Text(lm.translate(
                "Seconds for one full sensor sweep. Applies only while this window is open; the default cadence is restored after closing.",
                "全部传感器刷新一轮所需秒数。仅在本窗口打开期间生效，关闭后恢复程序默认刷新速度。"
            ))
            .font(.system(size: 8))
            .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text(lm.translate("Cycle:", "间隔:"))
                    .font(.system(size: 9))

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
                            .font(.system(size: 8, design: .monospaced))
                            .frame(width: 30)
                            .multilineTextAlignment(.center)
                            .onChange(of: intervalInput) { _, newValue in
                                commit(newValue)
                            }
                            .onSubmit { submit() }
                        Text(lm.translate("sec", "秒"))
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }

                // Explicit commit button flush right of the stepper (CHANGE-049)
                Button(action: { commit(intervalInput) }, label: {
                    Text(lm.translate("Apply", "应用"))
                        .font(.system(size: 9))
                })
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .frame(width: 44)

                Spacer()

                // Live "applies right now" indicator, occupying the same slot
                // as the CPU-avg indicator of the threshold section.
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(lm.translate("Active", "生效中"))
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
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
