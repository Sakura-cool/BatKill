//  FanFixedSpeedControls.swift
//  BatKill
//
//  Fixed-speed (定速) controls for a fan's manual sub-mode: a speed slider
//  with +/- steppers and min/max labels. The slider applies the speed
//  automatically after a 0.1s debounce (no separate "Set Speed" button);
//  the admin authorization flow is kept.

import SwiftUI

/// SwiftUI view rendering a fan's fixed-speed controls.
struct FanFixedSpeedControls: View {
    let fan: FanInfo
    let lm: LocalizationManager
    let hardwareMonitor: HardwareMonitor

    @Binding var pendingSpeed: Double
    let needsAdmin: Bool

    /// Called with the pending speed after the 0.1s debounce elapses.
    var onSetSpeed: (Double) -> Void
    /// Called when the user taps "Authorize Admin".
    var onAuthorize: () -> Void

    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "minus")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Slider(value: $pendingSpeed, in: 0...fan.maxSpeed, step: 100)
                    .onChange(of: pendingSpeed) { newValue in
                        scheduleApply(newValue)
                    }

                Image(systemName: "plus")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(String(format: "%d", Int(pendingSpeed)))
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 50, alignment: .trailing)
            }

            HStack {
                Text(lm.translate("Min: %d", "最小: %d", Int(fan.minSpeed)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(lm.translate("Max: %d", "最大: %d", Int(fan.maxSpeed)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                if needsAdmin {
                    Button(action: onAuthorize) {
                        Label(lm.translate("Authorize Admin", "授权管理员"), systemImage: "lock.shield")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.orange)
                }

                Spacer()
            }
            .padding(.top, 2)
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }

    /// Cancels any pending apply and schedules a new one 0.1s later so
    /// rapid slider drags coalesce into a single SMC write (CHANGE-018).
    private func scheduleApply(_ value: Double) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: fanApplyDebounceNs)
            guard !Task.isCancelled else { return }
            onSetSpeed(value)
        }
    }
}
