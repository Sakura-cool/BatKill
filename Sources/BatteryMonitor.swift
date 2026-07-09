import Foundation
import IOKit.ps
import Combine

/// Observes the Mac power source and publishes battery/AC state.
final class BatteryMonitor: ObservableObject {
    @Published var isOnBattery: Bool = false
    @Published var powerSource: String = "Unknown"
    @Published var batteryPercentage: Double = 0

    private var timer: Timer?
    private var notificationSource: CFRunLoopSource?

    // ──────────────────────────────────────────────
    // MARK: - Initialization
    // ──────────────────────────────────────────────
    init() {
        checkPowerState()
        registerIOKitCallback()
        // Poll every 5 s as a safety net
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkPowerState()
        }
    }

    deinit {
        timer?.invalidate()
        if let source = notificationSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Power State Check
    // ──────────────────────────────────────────────
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

    // ──────────────────────────────────────────────
    // MARK: - IOKit Notification (instant changes)
    // ──────────────────────────────────────────────
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
