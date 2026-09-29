//  NativeSegmentedPicker.swift
//  BatKill
//
//  Fixed-width NSSegmentedControl wrapper (CHANGE-034).
//  SwiftUI's SegmentedPickerStyle draws an NSSegmentedControl whose width
//  follows the label text's intrinsic size; in English the ideal width
//  hovers near the frame width, so each refresh renegotiates the width and
//  the control visibly stretches ~5pt then snaps back. Pinning the
//  intrinsicContentSize and using .fillEqually makes the width constant in
//  every language.

import AppKit
import SwiftUI

/// NSSegmentedControl subclass whose intrinsic width is fixed, so SwiftUI
/// can never renegotiate it from the label text.
final class FixedWidthSegmentedControl: NSSegmentedControl {
    /// Fixed control width in points (pinned, not proposed).
    var fixedWidth: CGFloat = 162

    override var intrinsicContentSize: NSSize {
        NSSize(width: fixedWidth, height: super.intrinsicContentSize.height)
    }
}

/// Native three-segment picker with a pixel-stable width.
struct NativeSegmentedPicker: NSViewRepresentable {
    /// Segment titles in display order.
    let titles: [String]
    /// Selected segment index (0-based).
    @Binding var selection: Int
    /// Fixed control width in points.
    var width: CGFloat = 162

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FixedWidthSegmentedControl {
        let control = FixedWidthSegmentedControl(
            labels: titles,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        control.fixedWidth = width
        control.segmentDistribution = .fillEqually
        control.selectedSegment = selection
        return control
    }

    func updateNSView(_ control: FixedWidthSegmentedControl, context: Context) {
        if control.segmentCount != titles.count {
            control.segmentCount = titles.count
            for (i, title) in titles.enumerated() {
                control.setLabel(title, forSegment: i)
            }
        } else {
            for (i, title) in titles.enumerated()
            where control.label(forSegment: i) != title {
                control.setLabel(title, forSegment: i)
            }
        }
        if control.selectedSegment != selection {
            control.selectedSegment = selection
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize,
                      nsView: FixedWidthSegmentedControl,
                      context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject {
        var parent: NativeSegmentedPicker

        init(_ parent: NativeSegmentedPicker) {
            self.parent = parent
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            parent.selection = sender.selectedSegment
        }
    }
}
