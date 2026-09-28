//  FanStatusBadge.swift
//  BatKill
//
//  Status badge shown next to a fan's mode picker (CHANGE-022): an icon +
//  short label that reflects whether the applied target speed has converged
//  to the read-back speed (机械迟滞收敛后判定「已生效」).

import SwiftUI

/// Tolerance (RPM) for judging a write as effective. Accounts for the fan's
/// mechanical settling time: the initial gap between target and read-back
/// is large, then converges to a small stable difference.
let fanAppliedTolerance: Double = 250

/// Compact status badge: (icon) 已生效 / 生效中 / 已恢复自动 / 未设定.
struct FanStatusBadge: View {
    let isManual: Bool
    let target: Double?
    let currentSpeed: Double
    let lm: LocalizationManager

    private var converged: Bool {
        guard let target else { return false }
        return abs(currentSpeed - target) <= fanAppliedTolerance
    }

    var body: some View {
        let (text, systemImage, color): (String, String, Color) = {
            if !isManual {
                return (lm.translate("Auto restored", "已恢复自动"),
                        "arrow.uturn.left.circle.fill", .green)
            }
            if converged {
                return (lm.translate("Applied", "已生效"),
                        "checkmark.circle.fill", .green)
            }
            if target != nil {
                return (lm.translate("Applying…", "生效中…"),
                        "hourglass.circle", .orange)
            }
            return (lm.translate("Not set", "未设定"),
                    "circle.dashed", .secondary)
        }()

        return HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }
}
