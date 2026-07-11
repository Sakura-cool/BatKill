//  BatteryMonitor.swift
//  BatKill
//
//  Monitors the Mac's power source via IOKit, publishing battery/AC state
//  changes to drive automatic app kill/restore behavior. Uses both an
//  IOKit notification callback for instant detection and a 5-second poll
//  timer as a safety net.
//
//  Note: The `logger()` function used throughout is defined in Core/Logger.swift.

import Foundation
import IOKit.ps
import Combine

/// Observes the Mac power source and publishes battery/AC state.
///
/// Publishes three properties consumed by the app's power action queue:
/// - `isOnBattery`: Primary signal for kill/restore decisions.
/// - `powerSource`: Display string ("Battery" or "AC Power").
/// - `batteryPercentage`: Current charge level (0-100).
///
/// Dual detection strategy:
/// 1. IOKit notification callback (`IOPSNotificationCreateRunLoopSource`)
///    fires immediately when the power source changes.
/// 2. A 5-second polling timer catches any missed notifications.
final class BatteryMonitor: ObservableObject {
    /// Whether the Mac is currently running on battery power.
    @Published var isOnBattery: Bool = false

    /// Display name for the current power source ("Battery" or "AC Power").
    @Published var powerSource: String = "Unknown"

    /// Current battery charge percentage (0.0 - 100.0).
    @Published var batteryPercentage: Double = 0

    /// Safety-net polling timer for power state checks.
    private var timer: Timer?

    /// IOKit run loop source for power source change notifications.
    private var notificationSource: CFRunLoopSource?

    // MARK: - Initialization

    /// Performs an initial power state check, registers the IOKit
    /// notification callback, and starts the polling timer.
    init() {
        checkPowerState()
        registerIOKitCallback()
        // Poll every 5 s as a safety net in case IOKit callbacks are missed
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkPowerState()
        }
    }

    /// Cleans up the timer and removes the IOKit run loop source.
    deinit {
        timer?.invalidate()
        if let source = notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    // MARK: - Power State Check

    /// Queries IOKit for the current power source state, battery capacity,
    /// and updates the published properties. If `isOnBattery` has changed,
    /// the new value is published (which triggers the app's kill/restore queue).
    func checkPowerState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }

            if let state = desc[kIOPSPowerSourceStateKey] as? String {
                let onBattery = (state == kIOPSBatteryPowerValue)
                logger("IOKit state=\(state) → onBattery=\(onBattery) (prev=\(self.isOnBattery))")
                powerSource = onBattery ? "Battery" : "AC Power"
                if isOnBattery != onBattery {
                    logger("⚡ isOnBattery changed: \(self.isOnBattery) → \(onBattery)")
                    isOnBattery = onBattery
                }
            }

            if let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
               let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int,
               maxCapacity > 0 {
                batteryPercentage = Double(capacity) / Double(maxCapacity) * 100.0
            }

            break // first power source is sufficient
        }
    }

    // MARK: - IOKit Notification (Instant Changes)

    /// Registers an IOKit callback that fires immediately when the power
    /// source changes (e.g., charger plugged/unplugged). The callback
    /// dispatches `checkPowerState()` on the main thread.
    private func registerIOKitCallback() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let callback: IOPowerSourceCallbackType = { context in
            guard let ctx = context else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { monitor.checkPowerState() }
        }

        notificationSource = IOPSNotificationCreateRunLoopSource(callback, ctx)?
            .takeRetainedValue()
        if let source = notificationSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }
}
