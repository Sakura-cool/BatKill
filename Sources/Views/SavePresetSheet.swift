//  SavePresetSheet.swift
//  BatKill
//
//  Compact "Save Preset" dialog that previews what will be saved per fan:
//    - Auto   → green "自动" badge
//    - Fixed  → blue badge + pending speed
//    - Curve  → orange badge + a small temperature-speed curve thumbnail
//  Kept small: name field + one row per fan + save/cancel.

import SwiftUI

/// Preview row for a single fan inside the save-preset dialog.
struct SavePresetFanRow: View {
    let fan: FanInfo
    let isAuto: Bool
    let subMode: ManualSubMode
    let speed: Double
    let curve: FanCurve?
    let lm: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            Text(fan.name)
                .font(.caption).fontWeight(.medium)
                .frame(width: 46, alignment: .leading)

            modeBadge

            Spacer()

            if !isAuto && subMode == .curve {
                if let curve {
                    HStack(spacing: 6) {
                        Text("\(Self.rangeText(curve.curveRange.min, curve.curveRange.max))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        CurveThumbnail(curve: curve)
                            .frame(width: 56, height: 18)
                    }
                } else {
                    Text("—")
                        .font(.caption2).foregroundColor(.secondary)
                }
            } else if !isAuto {
                Text(Self.rpmText(speed))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Formats a fan speed: ≥1000 → "x.xk" (one decimal, truncated, no
    /// rounding up); below 1000 → integer RPM.
    private static func rpmText(_ value: Double) -> String {
        if value >= 1000 {
            let k = value / 1000
            let truncated = (k * 10).rounded(.down) / 10
            return String(format: "%.1fk", truncated)
        }
        return "\(Int(value))"
    }

    private static func rangeText(_ min: Double, _ max: Double) -> String {
        "\(rpmText(min)) - \(rpmText(max))"
    }

    private var modeBadge: some View {
        let (text, color) = badgeContent
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(5)
    }

    private var badgeContent: (String, Color) {
        if isAuto { return (lm.translate("Auto", "自动"), .green) }
        if subMode == .curve { return (lm.translate("Curve", "调速"), .orange) }
        return (lm.translate("Fixed", "定速"), .blue)
    }
}

/// Minimal temperature-speed polyline for the save dialog preview.
struct CurveThumbnail: View {
    let curve: FanCurve

    var body: some View {
        GeometryReader { geo in
            let stepCount = FanCurve.maxStepIndex(for: curve.threshold)
            let maxStep = max(stepCount, 1)
            let speeds = curve.stepSpeeds.values
            let minY = speeds.min() ?? 0
            let range = max((speeds.max() ?? 100) - minY, 1)

            Path { p in
                for k in 0...maxStep {
                    let t = FanCurve.temperature(atStep: k, threshold: curve.threshold)
                    let x = geo.size.width * CGFloat(t) / CGFloat(max(curve.threshold, 1))
                    let speed = curve.stepSpeeds[k] ?? minY
                    let y = geo.size.height * (1 - CGFloat((speed - minY) / range))
                    let pt = CGPoint(x: x, y: y)
                    if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .background(Color.orange.opacity(0.06))
        .cornerRadius(3)
        .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
    }
}

/// Compact save-preset dialog.
struct SavePresetSheet: View {
    let fans: [FanInfo]
    let autoModes: [Int: Bool]
    let subModes: [Int: ManualSubMode]
    let pendingSpeeds: [Int: Double]
    let curves: [Int: FanCurve]
    let lm: LocalizationManager

    @State private var presetName: String = ""
    var onSave: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lm.translate("Save Preset", "保存预设"))
                .font(.headline)

            TextField(lm.translate("Preset name", "预设名称"), text: $presetName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(fans) { fan in
                        SavePresetFanRow(
                            fan: fan,
                            isAuto: autoModes[fan.index] ?? true,
                            subMode: subModes[fan.index] ?? .fixed,
                            speed: pendingSpeeds[fan.index] ?? fan.currentSpeed,
                            curve: curves[fan.index],
                            lm: lm
                        )
                    }
                }
            }
            .frame(maxHeight: 110)

            Divider()

            HStack {
                Spacer()
                Button(lm.translate("Cancel", "取消"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(lm.translate("Save", "保存")) {
                    onSave(presetName)
                }
                .buttonStyle(.borderedProminent)
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
