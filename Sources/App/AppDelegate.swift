//  AppDelegate.swift
//  BatKill
//
//  Central coordinator for the entire application. Owns every subsystem
//  (BatteryMonitor, AppLister, ProcessKiller, HardwareMonitor, etc.) and
//  glues them together.
//
//  Responsibilities:
//    - Single-instance enforcement on launch
//    - Menu-bar setup via MenuBarManager
//    - Window lifecycle (settings, temperature)
//    - Power-action queue with debounce and cooldown
//    - Badge rendering driven by Combine subscriptions
//
//  Architecture notes:
//    The power-action queue uses `pendingPowerAction: Bool?` to encode three
//    states: nil = nothing pending, true = battery action (kill), false = AC
//    action (restore). Rapid power-source transitions (fast plug/unplug) are
//    coalesced by simply overwriting `pendingPowerAction` -- only the final
//    state ever executes. After each completed action a 30-second cooldown
//    timer prevents thrashing.

import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UserNotifications

// MARK: - App Delegate

/// The NSApplicationDelegate that owns every subsystem and orchestrates
/// power-state transitions, window management, and badge updates.
///
/// Entry point is main.swift (not @main on this class) to avoid SwiftUI's
/// `App` protocol, which creates a persistent scene view graph that AppKit
/// renders in display cycles even when idle (~2-6% CPU).
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Subsystem References

    /// Monitors AC/battery power state via IOKit.
    let batteryMonitor      = BatteryMonitor()
    /// Discovers installed applications, launch agents, and background services.
    let appLister           = AppLister()
    /// Handles process termination and restoration with persistence.
    let processKiller       = ProcessKiller()
    /// Shared localization manager for English/Chinese translations.
    let localizationManager = LocalizationManager.shared
    /// Checks GitHub for new releases.
    let versionChecker      = VersionChecker()
    /// Downloads and installs updates (depends on versionChecker).
    lazy var updater        = Updater(checker: versionChecker)
    /// Reads CPU temperatures and fan speeds via SMC.
    let hardwareMonitor     = HardwareMonitor()

    // MARK: - UI References

    /// Manages the NSStatusItem (menu-bar icon, badge, popover, context menu).
    private var menuBarManager: MenuBarManager?

    /// Tracks whether the first app-list load has completed and the badge
    /// has been shown at least once.
    private var hasAppeared      = false

    /// Reference to the settings window so we can avoid creating duplicates.
    private var settingsWindow: NSWindow?

    /// Reference to the temperature/hardware-monitor window.
    private var temperatureWindow: NSWindow?

    /// Combine subscriptions for power state, app list, and restore count.
    private var cancellables     = Set<AnyCancellable>()

    // MARK: - Power-Action Queue

    /// Coalesced power action waiting to be processed.
    /// - `nil`: no action pending
    /// - `true`: battery -- kill selected apps
    /// - `false`: AC power -- restore killed apps
    ///
    /// When the user rapidly plugs/unplugs power, successive calls to
    /// `queuePowerAction(isOnBattery:)` simply overwrite this value.
    /// Only the **final** state is ever acted upon.
    private var pendingPowerAction: Bool?

    /// True while a kill or restore operation is in flight. Prevents
    /// overlapping operations from racing.
    private var powerActionInProgress = false

    /// Timer for the post-action cooldown period. During this window,
    /// `processNextPowerAction()` is blocked even if a new action is pending.
    private var powerDelayTimer: Timer?

    /// Seconds to wait after completing a power action before allowing
    /// the next queued action to proceed. Prevents rapid thrashing when
    /// the power source flickers.
    private let powerActionDelaySeconds: TimeInterval = 30

    /// Current power action context for structured logging.
    private var powerActionContext: LogContext?

    // MARK: - Auto-Kill Preference

    /// Convenience accessor for the `autoKillEnabled` user default.
    private var autoKillEnabled: Bool {
        UserDefaults.standard.bool(forKey: "autoKillEnabled")
    }

    // ──────────────────────────────────────────────
    // MARK: - Single Instance
    // ──────────────────────────────────────────────

    /// Checks if another instance of BatKill is already running.
    /// If so, activates the existing instance and terminates this one.
    /// Returns true when the current instance should stop launching.
    private func enforceSingleInstance() -> Bool {
        let current = NSRunningApplication.current
        let bundleID = current.bundleIdentifier ?? ""
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == bundleID && app != current {
                logger("enforceSingleInstance: found existing instance, activating & exiting")
                if #available(macOS 14.0, *) {
                    app.activate()
                } else {
                    app.activate(options: .activateIgnoringOtherApps)
                }
                NSApp.terminate(nil)
                return true
            }
        }
        return false
    }

    // ──────────────────────────────────────────────
    // MARK: - Launch
    // ──────────────────────────────────────────────

    /// Called once after the app finishes launching. Handles CLI fan-write
    /// arguments (admin re-launch), enforces single instance, sets up the
    /// menu bar, refreshes the app list, checks for updates, and begins
    /// observing state changes for badge updates and power actions.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // If this is an admin re-launch for fan writing, handle the CLI
        // arguments and exit immediately -- no UI setup needed.
        if handleCLIArgs() { return }

        // Prevent duplicate instances.
        if enforceSingleInstance() { return }

        // 1. Create and configure the menu bar icon + popover.
        let mgr = MenuBarManager()
        menuBarManager = mgr

        // Connect rapid-click gesture to debug logging toggle
        mgr.onRapidClickDetected = { [weak self] in
            DebugLogger.toggle()
            let state = DebugLogger.isEnabled ? "ON" : "OFF"
            self?.menuBarManager?.showBriefNotification("Debug Logging: \(state)", duration: 2)
        }

        let pv = PopoverView(
            batteryMonitor: batteryMonitor, appLister: appLister,
            processKiller: processKiller, lm: localizationManager)
        mgr.setPopoverContent(pv)

        // 2. Begin scanning installed applications.
        appLister.refreshAppList()

        // 3. Request notification authorization once at launch (instead of
        //    per-kill/restore, which would spam the user with permission prompts).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error = error {
                logger("Notification authorization failed: \(error.localizedDescription)")
            }
        }

        // 4. Check GitHub for a new release in the background, but defer
        //    by 30s to avoid slowing cold-start and to respect network latency.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
            self?.versionChecker.checkForUpdate()
        }

        // 5. Listen for window-open requests via NotificationCenter.
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSettingsWindow),
            name: .showSettings, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(showTemperatureWindow),
            name: .showTemperature, object: nil)

        // 6. Subscribe to state changes for badge and power actions.
        observeStateChanges()

        // 7. If launched with --diagnose-fan, auto-open the Temperature window
        //    and start logging CPU usage so we can measure the impact of
        //    having the hardware monitor window open with fan controls visible.
        if CommandLine.arguments.contains("--diagnose-fan") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.diagnoseFan()
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Window Management
    // ──────────────────────────────────────────────

    /// Opens (or focuses) the Settings window. If the window already exists
    /// and is visible, it is brought to the front. Otherwise a new window
    /// is created hosting a SwiftUI ContentView with all environment objects.
    @objc func showSettingsWindow() {
        logger("showSettingsWindow: called, settingsWindow=\(settingsWindow != nil), isVisible=\(settingsWindow?.isVisible ?? false)")

        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        settingsWindow?.close()
        settingsWindow = nil

        let contentView = SettingsView()
            .environmentObject(batteryMonitor)
            .environmentObject(appLister)
            .environmentObject(processKiller)
            .environmentObject(localizationManager)
            .environmentObject(versionChecker)
            .environmentObject(updater)
            .environmentObject(hardwareMonitor)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "BatKill"
        window.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable])
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 500, height: 640))
        window.center()
        window.makeKeyAndOrderFront(nil as NSWindow?)
        settingsWindow = window
        activateApp()
    }

    /// Opens (or focuses) the Temperature / Hardware Monitor window.
    @objc func showTemperatureWindow() {
        if let win = temperatureWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        temperatureWindow?.close()
        temperatureWindow = nil

        let contentView = TemperatureView(hardwareMonitor: hardwareMonitor, lm: localizationManager)
            .environmentObject(hardwareMonitor)
            .environmentObject(localizationManager)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Temperature"
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 420, height: 340))
        window.center()
        window.makeKeyAndOrderFront(nil)
        temperatureWindow = window
        activateApp()
    }

    /// Brings the application to the foreground, activating it so its
    /// windows become key. Uses the macOS 14+ API when available.
    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindow {
            settingsWindow = nil
        } else if window === temperatureWindow {
            temperatureWindow = nil
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Diagnose Mode
    // ──────────────────────────────────────────────

    /// Launched via `--diagnose-fan`. Opens the Temperature window, sets
    /// the fan to a manual speed (simulating user adjustment), and logs
    /// BatKill's CPU usage every 5 seconds.
    private func diagnoseFan() {
        showTemperatureWindow()
        logger("=== DIAGNOSE: Temperature window opened ===")

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            logger("=== DIAGNOSE: Starting baseline CPU log ===")
            self.startCPULogging(phase: "baseline")

            // After 10s of baseline, set the fan to manual + speed
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                self.setFanForDiagnose()
            }
        }
    }

    /// Attempts to set fan to manual mode at 50% max speed. Logs success
    /// or failure. Admin auth dialog may appear.
    private func setFanForDiagnose() {
        guard !hardwareMonitor.fans.isEmpty else {
            logger("=== DIAGNOSE: No fans found, skipping fan adjustment ===")
            return
        }

        logger("=== DIAGNOSE: Setting fan speed... ===")
        if hardwareMonitor.requestAdminAuth() {
            for fan in hardwareMonitor.fans {
                let speed = fan.maxSpeed * 0.5
                hardwareMonitor.setFanModeWithAdmin(fanIndex: fan.index, auto: false) { ok in
                    logger("DIAGNOSE: Fan[\(fan.index)] mode→manual: \(ok)")
                }
                hardwareMonitor.setFanSpeedWithAdmin(fanIndex: fan.index, speed: speed) { ok in
                    logger("DIAGNOSE: Fan[\(fan.index)] speed→\(Int(speed)): \(ok)")
                }
            }
            // After fan adjustment, wait and start post-adjustment CPU log
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.menuBarManager?.showBriefNotification("DIAGNOSE: fan set. Check CPU in log.", duration: 5)
                self?.startCPULogging(phase: "after-fan")
            }
        } else {
            logger("=== DIAGNOSE: Admin auth denied or failed ===")
        }
    }

    /// Runs `ps` every 5 seconds in the background and logs BatKill's
    /// CPU percentage to the file log. `phase` labels the log entries.
    private func startCPULogging(phase: String) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            let logInterval: TimeInterval = 5.0
            var iteration = 0
            while self != nil {
                iteration += 1
                let pid = ProcessInfo.processInfo.processIdentifier

                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/ps")
                task.arguments = ["-p", "\(pid)", "-o", "%cpu=%MEM="]

                let pipe = Pipe()
                task.standardOutput = pipe

                do {
                    try task.run()
                    task.waitUntilExit()

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    if !output.isEmpty {
                        logger("DIAGNOSE [\(phase) #\(iteration)] CPU=\(output)%")
                    }
                } catch {
                    logger("DIAGNOSE: ps failed: \(error.localizedDescription)")
                }

                Thread.sleep(forTimeInterval: logInterval)
            }
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Badge & State Observation
    // ──────────────────────────────────────────────

    /// Sets up Combine subscriptions that drive badge updates and trigger
    /// power actions when the battery state or app list changes.
    private func observeStateChanges() {
        // When battery state changes, refresh the badge and enqueue a kill/restore.
        batteryMonitor.$isOnBattery
            .sink { [weak self] newValue in
                guard let self = self, appLister.hasLoaded else { return }
                // Sync battery state to hardware monitor so views can adapt
                self.hardwareMonitor.isRunningOnBattery = newValue
                self.refreshBadge()
                self.queuePowerAction(isOnBattery: newValue)
            }
            .store(in: &cancellables)

        // When the app list changes, refresh the badge (count may change).
        appLister.$apps
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)

        // When pending restore count changes, refresh the badge.
        processKiller.$pendingRestoreCount
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)

        // On first successful app-list load, show the badge and trigger
        // the initial power action if the machine is already on battery.
        appLister.$hasLoaded
            .sink { [weak self] loaded in
                guard loaded, let self = self, !self.hasAppeared else { return }
                self.hasAppeared = true
                self.refreshBadge()
                self.queuePowerAction(isOnBattery: batteryMonitor.isOnBattery)
            }
            .store(in: &cancellables)
    }

    /// Updates the menu-bar badge count. On battery, shows the number of
    /// selected-and-running apps. On AC power, shows the pending restore count.
    private func refreshBadge() {
        guard appLister.hasLoaded else { return }
        let count = batteryMonitor.isOnBattery
            ? appLister.apps.filter { $0.isSelected && $0.isRunning }.count
            : processKiller.pendingRestoreCount
        menuBarManager?.updateBadge(count: count)
    }

    // ──────────────────────────────────────────────
    // MARK: - Power-Action Queue
    // ──────────────────────────────────────────────

    /// Enqueue a power-state transition.
    ///
    /// Rapid successive calls coalesce -- only the **latest** state is
    /// retained in `pendingPowerAction`. If no operation is in progress
    /// and no cooldown timer is active, the action executes immediately.
    private func queuePowerAction(isOnBattery: Bool) {
        let ctx = LogContext(name: "queuePowerAction")
        powerActionContext = ctx
        ctx.log("电源状态: \(isOnBattery ? "电池" : "交流电"), inProgress=\(powerActionInProgress), hasTimer=\(powerDelayTimer != nil)")
        pendingPowerAction = isOnBattery
        processNextPowerAction()
    }

    private func processNextPowerAction() {
        guard !powerActionInProgress, powerDelayTimer == nil, let onBattery = pendingPowerAction else {
            powerActionContext?.debug("跳过: inProgress=\(powerActionInProgress), hasTimer=\(powerDelayTimer != nil), pending=\(pendingPowerAction != nil)")
            return
        }

        pendingPowerAction = nil
        powerActionInProgress = true
        
        let ctx = powerActionContext ?? LogContext(name: "powerAction")
        let actionCtx = ctx.child(onBattery ? "killSelected" : "restoreKilledApps")
        actionCtx.log("开始执行 \(onBattery ? "终止" : "恢复") 操作")

        if onBattery {
            if autoKillEnabled {
                processKiller.killSelected(appLister.apps, context: actionCtx) { [weak self] in
                    self?.appLister.refreshAppList()
                    self?.onPowerActionCompleted(onBattery: onBattery)
                }
            } else {
                actionCtx.log("autoKill 未启用，跳过")
                onPowerActionCompleted(onBattery: onBattery)
            }
        } else {
            processKiller.restoreKilledApps(using: appLister.apps, context: actionCtx) { [weak self] in
                self?.appLister.refreshAppList()
                self?.onPowerActionCompleted(onBattery: onBattery)
            }
        }
    }

    private func onPowerActionCompleted(onBattery: Bool) {
        powerActionInProgress = false
        
        let ctx = powerActionContext ?? LogContext(name: "powerAction")
        ctx.log("操作完成，启动 \(Int(powerActionDelaySeconds))s 冷却定时器")

        let msg: String
        if onBattery {
            msg = localizationManager.translate(
                "Battery: will stop selected apps in \(Int(powerActionDelaySeconds))s",
                "电池供电：\(Int(powerActionDelaySeconds))秒后停止选中程序")
        } else {
            msg = localizationManager.translate(
                "AC connected: will restore stopped apps in \(Int(powerActionDelaySeconds))s",
                "已接通电源：\(Int(powerActionDelaySeconds))秒后恢复已停止程序")
        }
        menuBarManager?.showBriefNotification(msg)

        powerDelayTimer = Timer.scheduledTimer(withTimeInterval: powerActionDelaySeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.powerDelayTimer = nil
            self.powerActionContext?.log("冷却结束，处理下一个操作")
            self.processNextPowerAction()
        }
        powerDelayTimer?.tolerance = 5.0
    }
}
