//  AdminGateOverlay.swift
//  BatKill
//
//  Blurred overlay covering fan presets + fan control while the user has
//  not authorized admin access (CHANGE-017). Shows a centered authorize
//  button; the overlay stays (with a hint) if the user declines.

import SwiftUI

/// Blurred gate over the fan sections, with a centered authorize button.
struct AdminGateOverlay: View {
    let notEnabled: Bool
    let lm: LocalizationManager
    let onAuthorize: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.white)
                Button(action: onAuthorize) {
                    Label(lm.translate("Enable Fan Control", "启用风扇控制"),
                          systemImage: "lock.shield")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)

                if notEnabled {
                    Text(lm.translate("Fan control requires a one-time admin authorization",
                                      "风扇控制需要一次性管理员授权"))
                        .font(.caption2)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(16)
        }
        .cornerRadius(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }
}
