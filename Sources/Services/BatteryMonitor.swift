//  BatteryMonitor.swift
//  BatKill
//
//  Monitors the Mac's power source via IOKit, publishing battery/AC state
//  changes to drive automatic app kill/restore behavior. Uses the IOKit
//  notification callback (`IOPSNotificationCreateRunLoopSource`) for
//  instant detection. No polling timer — IOKit notifications are reliable
//  on modern macOS and periodic polling only adds CPU spikes.
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
/// Detection: IOKit notification callback (`IOPSNotificationCreateRunLoopSource`)
/// fires immediately when the power source changes. No polling timer — the
/// notification is instant and reliable on modern macOS, and periodic polling
/// would only add unnecessary CPU spikes.
final class BatteryMonitor: ObservableObject {
    /// Whether the Mac is currently running on battery power.
    @Published var isOnBattery: Bool = false

    /// Display name for the current power source ("Battery" or "AC Power").
    @Published var powerSource: String = "Unknown"

    /// Current battery charge percentage (0.0 - 100.0).
    @Published var batteryPercentage: Double = 0

    /// IOKit run loop source for power source change notifications.
    /// This is the PRIMARY detection mechanism. No polling timer is used
    /// because `IOPSNotificationCreateRunLoopSource` is instant and
    /// reliable on modern macOS, and any periodic IOKit PS call overhead
    /// shows up as CPU spikes that cause stutter in other apps.
    private var notificationSource: CFRunLoopSource?

    // MARK: - Initialization

    /// Performs an initial power state check and registers the IOKit
    /// notification callback. No polling timer — IOKit notifications
    /// alone are sufficient and introduce zero periodic CPU overhead.
    init() {
        checkPowerState()
        registerIOKitCallback()
    }

    /// Removes the IOKit run loop source on dealloc.
    deinit {
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
                powerSource = onBattery ? "Battery" : "AC Power"
                if isOnBattery != onBattery {
                    logger("⚡ isOnBattery changed: \(self.isOnBattery) → \(onBattery)")
                    isOnBattery = onBattery
                } else {
                    debugLog("IOKit state=\(state) → onBattery=\(onBattery)")
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
