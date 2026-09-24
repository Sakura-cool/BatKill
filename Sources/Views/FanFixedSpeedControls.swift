//  FanFixedSpeedControls.swift
//  BatKill
//
//  Fixed-speed (定速) controls for a fan's manual sub-mode: a speed slider
//  with +/- steppers, min/max labels, a "Set Speed" button, and the admin
//  authorization flow. Extracted from TemperatureView to keep that file
//  under the SwiftLint ratchet limits.

import SwiftUI

/// SwiftUI view rendering a fan's fixed-speed controls.
///
/// Parameter callbacks let the parent (TemperatureView) own the fan state
/// dictionaries while this view only renders and forwards user actions.
struct FanFixedSpeedControls: View {
    let fan: FanInfo
    let lm: LocalizationManager
    let hardwareMonitor: HardwareMonitor

    @Binding var pendingSpeed: Double
    let statusMessage: String?
    let needsAdmin: Bool

    /// Called with the pending speed when the user taps "Set Speed".
    var onSetSpeed: (Double) -> Void
    /// Called when the user taps "Authorize Admin".
    var onAuthorize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Speed slider with +/- buttons
            HStack(spacing: 8) {
                Image(systemName: "minus")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Slider(value: $pendingSpeed, in: 0...fan.maxSpeed, step: 100)

                Image(systemName: "plus")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Numeric readout of pending speed
                Text(String(format: "%d", Int(pendingSpeed)))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }

            // Min/Max speed labels
            HStack {
                Text(lm.translate("Min: %d", "最小: %d", Int(fan.minSpeed)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(lm.translate("Max: %d", "最大: %d", Int(fan.maxSpeed)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Action buttons: Set Speed, Authorize Admin, status message
            HStack(spacing: 8) {
                Button { onSetSpeed(pendingSpeed) } label: {
                    Label(lm.translate("Set Speed", "设定转速"), systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.blue)

                // Admin authorization button (shown after first failed attempt)
                if needsAdmin {
                    Button(action: onAuthorize) {
                        Label(lm.translate("Authorize Admin", "授权管理员"), systemImage: "lock.shield")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }

                // Status message after write attempt
                if let status = statusMessage {
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(needsAdmin ? .red : .green)
                }

                Spacer()
            }
            .padding(.top, 2)
        }
    }
}
