//  ThresholdSection.scala
//  BatKill
//
//  Fan temperature threshold section (v0.2.2, extracted v0.2.3 CHANGE-056).
//
//  Rendered as the top half of the shared threshold+refresh settings card of
//  the hardware monitor window. Exceeding the threshold releases fan control
//  to the system for safety. Inner content only — the shared card supplies
//  the chrome, so the layout mirrors `RefreshIntervalSection` exactly.

import SwiftUI

/// Fan temperature threshold section (inner content only — the shared settings
/// card supplies the chrome).
struct ThresholdSection: View {
    /// Hardware monitor supplying the live CPU die temperature and the
    /// thermal-throttle flag.
    @ObservedObject var monitor: HardwareMonitor

    /// Persisted threshold store (60-120 °C).
    @ObservedObject var store: TemperatureThresholdStore

    /// Localization manager.
    @ObservedObject var lm: LocalizationManager

    /// Text field content while the user is typing.
    @State private var thresholdInput = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "thermometer")
                    .foregroundColor(.orange)
                    .font(.system(size: 11.5))
                Text(lm.translate("Fan Temperature Threshold", "风扇温度阈值"))
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
            }

            Text(lm.translate(
                "When CPU exceeds this temperature, fan control is released to the system.",
                "当 CPU 超过此温度时，风扇控制将交还系统。"
            ))
            .font(.system(size: 9))
            .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Text(lm.translate("Threshold:", "阈值:"))
                    .font(.system(size: 10))

                // Field and unit sit OUTSIDE the stepper: with an empty title the
                // stepper renders only its arrows, so they can be scaled down
                // without softening the field text (CHANGE-052).
                HStack(spacing: 3) {
                    TextField("60-120", text: $thresholdInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 9, design: .monospaced))
                        .frame(width: 30)
                        .multilineTextAlignment(.center)
                        .onSubmit { applyThreshold() }
                    Text("°C")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Stepper("", value: Binding(
                        get: { store.threshold },
                        set: { newVal in
                            let clamped = min(120, max(60, newVal))
                            store.threshold = clamped
                            thresholdInput = "\(Int(clamped))"
                        }
                    ), in: 60...120, step: 1)
                    .controlSize(.mini)
                    .scaleEffect(0.8, anchor: .center)
                }

                // Explicit commit button flush right of the stepper (CHANGE-049)
                Button(action: { applyThreshold() }, label: {
                    Text(lm.translate("Apply", "应用"))
                        .font(.system(size: 10))
                })
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .frame(width: 44)

                Spacer()

                // Overheat danger warning
                if monitor.thermalThrottled {
                    Text(lm.translate("Overheat Danger!", "过温危险!"))
                        .font(.system(size: 10)).fontWeight(.bold)
                        .foregroundColor(.red)
                }

                // Live CPU Die temperature indicator
                let cpuTemp = monitor.smoothedCPUTemp
                HStack(spacing: 4) {
                    Text(lm.translate("CPU Avg:", "CPU 均温:"))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f°C", cpuTemp))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(cpuTemp >= store.threshold ? .red : .primary)
                    Circle()
                        .fill(cpuTemp >= store.threshold ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                }
            }
        }
        .onAppear { thresholdInput = "\(Int(store.threshold))" }
    }

    /// Commits the threshold field: keeps digits only, clamps into 60-120,
    /// persists, then re-syncs the field. Shared by the Enter key and the
    /// "Apply" button (CHANGE-049).
    private func applyThreshold() {
        let digits = thresholdInput.filter(\.isNumber)
        if let val = Int(digits) {
            store.threshold = Double(min(120, max(60, val)))
        }
        thresholdInput = "\(Int(store.threshold))"
    }
}
