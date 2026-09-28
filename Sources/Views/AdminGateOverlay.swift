//  AdminGateOverlay.swift
//  BatKill
//
//  Blurred overlay covering fan presets + fan control while the user has
//  not authorized admin access (CHANGE-017). Shows a centered authorize
//  button; the overlay stays (with a hint) if the user declines.

import SwiftUI

/// Blurred gate over the fan sections, with a centered authorize button.
struct AdminGateOverlay: View {
    let authDenied: Bool
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
                    Label(lm.translate("Authorize Admin", "管理员授权"),
                          systemImage: "lock.shield")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.blue)

                if authDenied {
                    Text(lm.translate("Admin authorization required to use fan controls",
                                      "只有管理员授权后才能使用风扇控制"))
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
