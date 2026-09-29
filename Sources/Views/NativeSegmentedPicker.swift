//  SegmentedModePicker.swift
//  BatKill
//
//  Compact fixed-width three-segment mode picker (CHANGE-036).
//  Pure SwiftUI buttons in a rounded capsule: font and height match the
//  fan-name label (caption, ~11pt) so the control sits inline with it
//  instead of towering over it. Width is pinned, so switching modes and
//  the 1s refresh never renegotiate the layout (no jitter, any language).

import SwiftUI

/// Compact three-segment picker: 自动 | 定速 | 调速.
struct SegmentedModePicker: View {
    /// Segment titles in display order.
    let titles: [String]
    /// Selected segment index (0-based).
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(titles.indices, id: \.self) { i in
                Button {
                    selection = i
                } label: {
                    Text(titles[i])
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundColor(selection == i ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selection == i
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear)
                                .padding(1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: 128, height: 19)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5)
                )
        )
        .fixedSize()
    }
}
