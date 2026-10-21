//  ThermalWarningBanner.swift
//  BatKill
//
//  Red banner displayed when the CPU temperature exceeds the configured
//  temperature threshold. Explains that fan control has been released to the
//  system (thermal safety guard).
//
//  Extracted from `TemperatureView` (v0.2.3 CHANGE-048) to keep that file
//  inside the SwiftLint type-body ratchet. Behaviour is unchanged.

import SwiftUI

/// Thermal warning banner for the hardware monitor window.
struct ThermalWarningBanner: View {
    /// Threshold store providing the configured limit in degrees Celsius.
    @ObservedObject var thresholdStore: TemperatureThresholdStore

    /// Hardware monitor providing the live maximum CPU temperature.
    @ObservedObject var hardwareMonitor: HardwareMonitor

    /// Localization manager.
    @ObservedObject var lm: LocalizationManager

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(lm.translate(
                    "CPU over \(Int(thresholdStore.threshold))°C — fan control released to system",
                    "CPU 超过 \(Int(thresholdStore.threshold))°C — 风扇控制已交还系统"
                ))
                .font(.caption).fontWeight(.medium)
                .foregroundColor(.white)
                Text(lm.translate(
                    "Current: \(String(format: "%.1f", hardwareMonitor.maxCPUTemp))°C",
                    "当前: \(String(format: "%.1f", hardwareMonitor.maxCPUTemp))°C"
                ))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.85))
        .cornerRadius(8)
    }
}
