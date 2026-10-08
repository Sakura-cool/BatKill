//  CompactSegmentedPicker.swift
//  BatKill
//
//  Compact fixed-size segmented controls built from pure SwiftUI buttons in
//  a rounded capsule. Fixed width/height keep the layout stable (no jitter
//  in any language) and render identically on arm64 and x86_64 — unlike the
//  built-in segmented Picker, whose metrics differ across architectures.

import SwiftUI

/// Generic compact segmented picker: N equal-width segments in a rounded
/// capsule. The selected segment gets a subtle accent tint.
struct CompactSegmentedPicker: View {
    /// Segment titles in display order.
    let titles: [String]
    /// Selected segment index (0-based).
    @Binding var selection: Int
    /// Fixed total width.
    let width: CGFloat

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
                                .fill(selection == i ? Color.accentColor.opacity(0.16) : Color.clear)
                                .padding(1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .frame(width: width, height: 19)
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

/// Compact two-segment language picker: English | 简体中文.
struct LanguagePicker: View {
    @Binding var selection: Language

    var body: some View {
        CompactSegmentedPicker(
            titles: Language.allCases.map(\.displayName),
            selection: Binding(
                get: { Language.allCases.firstIndex(of: selection) ?? 0 },
                set: { newValue in
                    if Language.allCases.indices.contains(newValue) {
                        selection = Language.allCases[newValue]
                    }
                }
            ),
            width: 100
        )
    }
}
