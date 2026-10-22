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
//  tightened; an explicit "Apply" button sits flush right of the stepper (it
//  re-commits the current field content, which is already live-applied).
//
//  CHANGE-051: `carded == false` drops the card chrome so this section can be
//  composed inside the shared threshold+refresh card; the stepper uses
//  `.controlSize(.mini)`; and the field is re-synced from the store so the
//  stepper arrows visibly move the number.
//
//  CHANGE-052/053: the stepper keeps an empty title so only its arrows can be
//  scaled down (`.scaleEffect(0.8)`); text then grew back by 1/4 (×1.25).
//
//  Scope: the value is only consumed by the temperature window's own refresh
//  timer, so closing the window restores the program's default cadence.

import SwiftUI

/// Refresh interval section, visually mirroring the temperature threshold
/// section (same padding, background, corner radius and icon-title-description
/// row structure).
struct RefreshIntervalSection: View {
    /// Persisted refresh interval store (1-9 seconds per full sweep).
    @ObservedObject var store: TemperatureRefreshIntervalStore

    /// Localization manager.
    @ObservedObject var lm: LocalizationManager

    /// Draws the card chrome (padding/background/corner radius). False when the
    /// section is embedded in the shared threshold+refresh card (CHANGE-051).
    var carded = true

    /// Text field content while the user is typing.
    @State private var intervalInput = ""

    var body: some View {
        if carded {
            cardContent
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
        } else {
            cardContent
        }
    }

    /// Card inner content, shared by the carded and embedded variants.
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundColor(.cyan)
                    .font(.system(size: 12.5))
                Text(lm.translate("Temperature Refresh Interval", "温度刷新间隔"))
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
            }

            Text(lm.translate(
                "Seconds for one full sensor sweep. Applies only while this window is open; the default cadence is restored after closing.",
                "全部传感器刷新一轮所需秒数。仅在本窗口打开期间生效，关闭后恢复程序默认刷新速度。"
            ))
            .font(.system(size: 10))
            .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text(lm.translate("Cycle:", "间隔:"))
                    .font(.system(size: 11))

                // Field and unit sit OUTSIDE the stepper: with an empty title the
                // stepper renders only its arrows, so they can be scaled down
                // without softening the 10pt field text (CHANGE-052).
                HStack(spacing: 3) {
                    TextField("1-9", text: $intervalInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 30)
                        .multilineTextAlignment(.center)
                        .onChange(of: intervalInput) { _, newValue in
                            commit(newValue)
                        }
                        .onSubmit { submit() }
                    Text(lm.translate("sec", "秒"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Stepper("", value: Binding(
                        get: { Double(store.seconds) },
                        set: { store.set(seconds: Int($0)) }
                    ), in: 1...9, step: 1)
                    .controlSize(.mini)
                    .scaleEffect(0.8, anchor: .center)
                }

                // Explicit commit button flush right of the stepper (CHANGE-049)
                Button(action: { commit(intervalInput) }, label: {
                    Text(lm.translate("Apply", "应用"))
                        .font(.system(size: 11))
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
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear { intervalInput = "\(store.seconds)" }
        // The stepper mutates the store without touching the field, so push the
        // new value back here — otherwise the arrows look inert (CHANGE-051).
        // Idempotent for the typing path, which already writes the same string.
        .onChange(of: store.seconds) { _, seconds in
            resync(seconds: seconds)
        }
    }

    /// Commits typed input immediately: keeps digits only, clamps into 1-9,
    /// persists, and re-syncs the field so the displayed value always equals
    /// the value actually driving the refresh timer.
    private func commit(_ raw: String) {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        let value = TemperatureRefreshIntervalStore.clamp(Int(digits) ?? store.seconds)
        store.set(seconds: value)
        resync(seconds: value)
    }

    /// Re-syncs the field with a value already committed to the store.
    private func resync(seconds: Int) {
        let display = "\(seconds)"
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
