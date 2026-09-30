//  PresetFanSummary.swift
//  BatKill
//
//  Compact per-fan summary inside a saved-preset row (CHANGE-038): colored
//  mode badge (Auto green / Fixed blue / Curve orange — same palette as the
//  save-preset dialog) plus speed info per the mode: "-" for auto, the set
//  value for fixed, and the user curve's min-max range for curve mode.

import SwiftUI

/// One-line summary of a single fan's mode and speed within a preset row.
struct PresetFanSummary: View {
    let fanName: String
    let isAuto: Bool
    let subMode: ManualSubMode
    let speed: Double
    let curve: FanCurve?
    /// Observed so the unit ("rpm"/"转/分") and mode badge refresh when the
    /// user switches language in Settings (CHANGE-038).
    @ObservedObject var lm: LocalizationManager

    var body: some View {
        HStack(spacing: 4) {
            Text(fanName)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
                .lineLimit(1)
            modeBadge
            Text(speedText)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .fixedSize()
    }

    private var modeBadge: some View {
        let (text, color) = badgeContent
        return Text(text)
            .font(.system(size: 7, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    private var badgeContent: (String, Color) {
        if isAuto { return (lm.translate("Auto", "自动"), .green) }
        if subMode == .curve { return (lm.translate("Curve", "调速"), .orange) }
        return (lm.translate("Fixed", "定速"), .blue)
    }

    private var speedText: String {
        if isAuto { return "-" }
        let unit = lm.translate("rpm", "转/分")
        if subMode == .curve {
            guard let curve else { return "—" }
            let range = curve.curveRange
            return "\(Int(range.min))-\(Int(range.max)) \(unit)"
        }
        return "\(Int(speed)) \(unit)"
    }
}
