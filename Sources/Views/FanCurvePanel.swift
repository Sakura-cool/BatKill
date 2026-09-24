//  FanCurvePanel.swift
//  BatKill
//
//  Temperature-curve editor for the fan control "调速" (curve) sub-mode.
//
//  Shows one speed stepper per 10 °C step (0 °C ... user threshold), with a
//  monotonicity hint and a note that temperatures above the threshold are
//  handed back to the system. Extracted from TemperatureView to keep that
//  file under the SwiftLint ratchet limits.

import SwiftUI

/// SwiftUI view rendering a fan's temperature-speed curve editor.
///
/// - Parameters:
///   - fan: The fan whose curve is being edited.
///   - curveStore: Shared store holding the fan's curve and sub-mode.
///   - lm: Localization manager for bilingual strings.
struct FanCurvePanel: View {
    let fan: FanInfo
    let curveStore: FanCurveStore
    let lm: LocalizationManager

    var body: some View {
        let curve = curveStore.curve(for: fan.index, currentSpeed: fan.currentSpeed)
        let maxStep = FanCurve.maxStepIndex(for: curve.threshold)

        return VStack(alignment: .leading, spacing: 4) {
            // Threshold line + monotonic hint
            HStack {
                Text(lm.translate("Curve up to %d °C", "调速曲线至 %d °C", Int(curve.threshold)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(lm.translate("Above threshold → system control", "超过阈值交由系统控制"))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }

            // One stepper per 10 °C step
            ForEach(0...maxStep, id: \.self) { step in
                let stepTemp = FanCurve.temperature(atStep: step, threshold: curve.threshold)
                let speed = curve.stepSpeeds[step] ?? fan.currentSpeed

                HStack(spacing: 6) {
                    Text("\(Int(stepTemp))°C")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .leading)

                    Stepper("", value: Binding(
                        get: { speed },
                        set: { newValue in
                            var updated = curve
                            updated.stepSpeeds[step] = newValue
                            curveStore.setCurve(updated, for: fan.index)
                        }
                    ), in: fan.minSpeed...fan.maxSpeed, step: 100)

                    Text("\(Int(speed))")
                        .font(.system(.caption2, design: .monospaced))
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
    }
}
