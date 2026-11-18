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

// MARK: - Contact Issue Choice (v0.2.6)

/// Choices presented by the power contact-issue dialog (design-spec §6.2 / AC-614).
enum ContactIssueChoice {
    /// Pause auto-restore (safe default); keep the pending restore list.
    case pause
    /// Clear the contact issue and continue the restore sequence.
    case ignore
    /// Cancel the restore and stay stopped; keep the pending restore list.
    case stop
}

// MARK: - App Delegate

/// The NSApplicationDelegate that owns every subsystem and orchestrates
/// power-state transitions, window management, and badge updates.
/// Entry point is main.swift (not @main on this class) to avoid SwiftUI's
/// `App` protocol, which creates a persistent scene view graph that AppKit
/// renders in display cycles even when idle (~2-6% CPU).
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {

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

    /// Title-bar version button, kept so it can be disabled while a manual
    /// update check / install is in progress.
    private weak var titleBarVersionButton: NSButton?

    /// Title-bar "?" help button (shows the built-in usage guide).
    private weak var titleBarHelpButton: NSButton?

    /// True during a manual update check or install; further title-bar
    /// version clicks are ignored until the flow finishes.
    private var isManualUpdateInFlight = false

    /// Combine subscriptions for power state, app list, and restore count.
    private var cancellables     = Set<AnyCancellable>()

    // MARK: - Restore Gating & Contact Issue (v0.2.6)

    /// Drives the power contact-issue choice dialog (AC-614). Set `true` when
    /// >= 3 AC/battery flips are detected within a 10s window; cleared when the
    /// user resolves the issue via `resolveContactIssue(_:)`.
    @Published var showContactIssueDialog = false

    /// Whether a power contact issue has been detected and the auto
    /// kill/restore loop is paused until the user chooses (AC-614).
    private var contactIssue = false

    /// Timestamps of AC/battery `isOnBattery` transitions (sliding 10s window),
    /// used to detect a loose power connection.
    private var powerFlipTimes: [Date] = []

    /// Last recorded battery state, used to detect actual flips (the initial
    /// app-list-load call is not a real transition and must not count).
    private var lastRecordedBatteryState = false

    /// Whether `lastRecordedBatteryState` has been initialized (the first
    /// `queuePowerAction` call reflects the current state, not a transition).
    private var hasRecordedBatteryState = false

    /// Sliding (timestamp, percentage) snapshots for AC-615~617 decline checks.
    private var batterySnapshots: [(time: Date, pct: Double)] = []

    /// Whether a rapid battery decline (AC-616) was already notified, so the
    /// warning is not repeated on every subsequent snapshot.
    private var rapidDeclineNotified = false

    /// Whether the charger-power-insufficient warning (AC-619) was already
    /// notified for the current weak-charger episode, re-armed when the
    /// condition clears (battery >=80%, on battery, or no longer declining).
    private var chargerPowerNotified = false

    /// Low-frequency battery re-evaluation timer (B1). `BatteryMonitor` publishes
    /// `batteryPercentage` only on IOKit power-source events; during steady
    /// charging below 20% there are no events, so AC-602 (resume at >=20%)
    /// would never fire. While the low-battery gate is held, poll every 30s;
    /// runs ONLY in the rare gated state (AC + <20%), so idle power is unaffected.
    private var lowBatteryGateTimer: Timer?

    // MARK: - Power-Action Queue

    // 三态语义（nil=无等待 / true=电池动作 / false=交流电动作），见 AGENTS.md「注意事项」；非可选布尔误用
    // swiftlint:disable discouraged_optional_boolean
    /// Coalesced power action waiting to be processed.
    /// - `nil`: no action pending
    /// - `true`: battery -- kill selected apps
    /// - `false`: AC power -- restore killed apps
    ///
    /// When the user rapidly plugs/unplugs power, successive calls to
    /// `queuePowerAction(isOnBattery:)` simply overwrite this value.
    /// Only the **final** state is ever acted upon.
    private var pendingPowerAction: Bool?
    // swiftlint:enable discouraged_optional_boolean

    /// True while a kill or restore operation is in flight. Prevents
    /// overlapping operations from racing.
    private var powerActionInProgress = false

    /// Timer for the post-action cooldown period. During this window,
    /// `processNextPowerAction()` is blocked even if a new action is pending.
    private var powerDelayTimer: Timer?

    /// Seconds to wait after completing a power action before allowing
    /// the next queued action to proceed. Prevents rapid thrashing on flicker.
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

    /// Checks if another instance of BatKill is already running; if so,
    /// activates it and terminates this one. Returns true to stop launching.
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
    /// menu bar, refreshes the app list, checks updates, begins observing
    /// state changes for badge updates and power actions.
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

        // 2. Clean up any stale config referencing core macOS system components
        //    (v0.2.4 CHANGE-060). Unfreezes suspended core components and removes
        //    them from all persisted keys so erroneous config no longer takes
        //    effect. Runs before the app list is refreshed.
        SystemCoreProtection.cleanupPersistedConfig()

        // 3. Begin scanning installed applications.
        appLister.refreshAppList()

        // 4. Request notification authorization once at launch (instead of
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
        observeUpdaterState()

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
            .environmentObject(self)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "BatKill"
        window.styleMask = NSWindow.StyleMask([.titled, .closable, .miniaturizable, .resizable])
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 500, height: 640))
        window.center()
        installTitleBarVersionAccessory(on: window)
        window.makeKeyAndOrderFront(nil as NSWindow?)
        settingsWindow = window
        activateApp()
    }

    /// Adds a title-bar accessory next to the window-traffic-light buttons
    /// showing a tappable "BatKill" name button plus a version label
    /// ("v0.1.6") and a "?" help button. Clicking the name opens the GitHub
    /// repo; clicking the version runs a manual update check; "?" shows the guide.
    private func installTitleBarVersionAccessory(on window: NSWindow) {
        // Hide the system-rendered title text; the accessory below renders
        // "BatKill vX.X.X" next to the traffic-light buttons instead.
        window.titleVisibility = .hidden

        let nameButton = NSButton(title: "BatKill",
                                  target: self,
                                  action: #selector(titleBarNameClicked))
        nameButton.isBordered = false
        nameButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameButton.contentTintColor = .labelColor
        nameButton.toolTip = localizationManager.translate(
            "Open GitHub repository", "打开 GitHub 仓库")
        nameButton.sizeToFit()

        let versionButton = NSButton(title: "v\(versionChecker.currentVersion)",
                                     target: self,
                                     action: #selector(titleBarVersionClicked))
        versionButton.isBordered = false
        versionButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        versionButton.contentTintColor = .secondaryLabelColor
        versionButton.toolTip = localizationManager.translate(
            "Check for updates", "点击检查更新")
        versionButton.sizeToFit()
        titleBarVersionButton = versionButton

        let helpButton = NSButton()
        helpButton.isBordered = false
        helpButton.image = NSImage(systemSymbolName: "questionmark.circle",
                                   accessibilityDescription: "Usage guide")
        helpButton.imagePosition = .imageOnly
        helpButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        helpButton.contentTintColor = .secondaryLabelColor
        helpButton.toolTip = localizationManager.translate("Usage guide", "使用说明书")
        helpButton.target = self
        helpButton.action = #selector(titleBarHelpClicked)
        helpButton.sizeToFit()
        titleBarHelpButton = helpButton

        // Height matches the standard title bar (~28pt) so the content
        // vertically centers against the traffic-light buttons.
        let leadingInset: CGFloat = 6
        let containerH: CGFloat = 28
        let container = NSView(
            frame: NSRect(x: 0, y: 0,
                          width: leadingInset + nameButton.frame.width + 8 + versionButton.frame.width + 8 + helpButton.frame.width,
                          height: containerH))
        nameButton.frame.origin = NSPoint(x: leadingInset,
                                          y: (containerH - nameButton.frame.height) / 2)
        versionButton.frame.origin = NSPoint(x: nameButton.frame.maxX + 8,
                                              y: (containerH - versionButton.frame.height) / 2)
        helpButton.frame.origin = NSPoint(x: versionButton.frame.maxX + 8,
                                          y: (containerH - helpButton.frame.height) / 2)
        container.addSubview(nameButton)
        container.addSubview(versionButton)
        container.addSubview(helpButton)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// Shows the built-in usage guide in a modal alert. Content mirrors
    /// docs/USAGE.md minus the installation section (the app is already
    /// installed when this is reachable).
    @objc private func titleBarHelpClicked() {
        let alert = NSAlert()
        alert.messageText = localizationManager.translate("BatKill Usage Guide", "BatKill 使用说明书")
        alert.informativeText = usageGuideText()
        alert.alertStyle = .informational
        alert.addButton(withTitle: localizationManager.translate("OK", "知道了"))
        if let win = settingsWindow {
            alert.beginSheetModal(for: win)
        } else {
            alert.runModal()
        }
    }

    /// Compact usage-guide body (no install steps; the app is running).
    private func usageGuideText() -> String {
        localizationManager.translate(
            "Battery saver:\n"
            + "1. Click the menu-bar battery icon → Settings\n"
            + "2. Tick apps to auto-stop on battery\n"
            + "3. Unplug → apps close after 30s; replug → they restore\n\n"
            + "Fan control:\n"
            + "1. Open the temperature window\n"
            + "2. First use: tap Enable Fan Control, enter admin password once\n"
            + "3. Per fan pick Auto / Fixed / Curve\n"
            + "   - Auto: system-managed\n"
            + "   - Fixed: drag the slider (applies after 0.1s)\n"
            + "   - Curve: edit nodes on the chart (applies after 0.1s)\n"
            + "4. Status badge next to the picker shows Applied/Applying\n\n"
            + "Presets:\n"
            + "Save the current layout, apply or delete saved presets.\n\n"
            + "Threshold guard:\n"
            + "Set 60-120°C; above it fans return to system control.",
            "电池省电：\n"
            + "1. 点菜单栏电池图标 → 设置\n"
            + "2. 勾选电池供电时自动停止的软件\n"
            + "3. 拔电源 → 30 秒后自动关闭；插回 → 自动恢复\n\n"
            + "风扇控制：\n"
            + "1. 打开温度窗口\n"
            + "2. 首次使用：点「启用风扇控制」并输入一次管理员密码\n"
            + "3. 每把风扇可选 自动 / 定速 / 调速\n"
            + "   - 自动：交还系统控制\n"
            + "   - 定速：拖动滑块（0.1 秒后生效）\n"
            + "   - 调速：编辑曲线节点（0.1 秒后生效）\n"
            + "4. 模式行状态徽标显示「已生效/生效中」\n\n"
            + "预设：\n"
            + "保存当前布局，一键应用或删除预设。\n\n"
            + "温度阈值保护：\n"
            + "设置 60-120°C，超过后风扇自动交还系统。"
        )
    }

    /// Opens the project's GitHub repository in the default browser when the
    /// title-bar app name is clicked.
    @objc private func titleBarNameClicked() {
        guard let url = URL(string: "https://github.com/Sakura-cool/BatKill") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Manual update check triggered by tapping the title-bar version label.
    /// Check, download, and install run as one locked flow; further clicks are
    /// ignored until the alert is dismissed or the flow finishes.
    @objc private func titleBarVersionClicked() {
        guard !isManualUpdateInFlight else {
            logger("Manual update check skipped: flow already in progress")
            return
        }
        isManualUpdateInFlight = true
        titleBarVersionButton?.isEnabled = false
        logger("Manual update check triggered from title bar")

        versionChecker.checkForUpdate { [weak self] result in
            guard let self else { return }
            switch result {
            case .hasUpdate:
                logger("Manual check: update available, starting download")
                self.updater.downloadAndInstall()
            case .upToDate:
                let msg = self.localizationManager.translate(
                    "You're up to date!", "已是最新版本")
                self.showUpdateAlert(msg) {
                    self.finishManualUpdateFlow()
                }
            case .failed:
                let msg = self.localizationManager.translate(
                    "Update check failed. Check your network and try again.",
                    "更新检查失败，请检查网络后重试。")
                self.showUpdateAlert(msg) {
                    self.finishManualUpdateFlow()
                }
            }
        }
    }

    /// Unlocks the title-bar version button after the manual update flow
    /// reaches a terminal state (alert dismissed or download finished).
    /// Success relaunches the app, so this normally only runs on failure.
    private func finishManualUpdateFlow() {
        isManualUpdateInFlight = false
        titleBarVersionButton?.isEnabled = true
    }

    /// Observes the updater: once a manual download ends (success relaunches,
    /// failure or install error returns here), release the update lock.
    private func observeUpdaterState() {
        updater.$isDownloading
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] downloading in
                guard let self, !downloading, self.isManualUpdateInFlight else { return }
                logger("Manual update download finished; releasing update lock")
                self.finishManualUpdateFlow()
            }
            .store(in: &cancellables)
    }

    /// Shows a simple modal information alert (used for up-to-date / failure).
    /// - Parameter completion: Called after the alert is dismissed.
    private func showUpdateAlert(_ message: String, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: localizationManager.translate("OK", "知道了"))
        if let win = settingsWindow {
            alert.beginSheetModal(for: win) { _ in
                completion?()
            }
        } else {
            alert.runModal()
            completion?()
        }
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
        window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable, NSWindow.StyleMask.miniaturizable, NSWindow.StyleMask.resizable]
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
    /// or failure. Requires the batkill-fan sudo channel (CHANGE-019).
    private func setFanForDiagnose() {
        guard !hardwareMonitor.fans.isEmpty else {
            logger("=== DIAGNOSE: No fans found, skipping fan adjustment ===")
            return
        }

        logger("=== DIAGNOSE: Setting fan speed... ===")
        if FanInstallManager.isSudoReady() {
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
            logger("=== DIAGNOSE: sudo 通道未就绪，跳过风扇调整 ===")
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

        // Battery percentage changes drive the low-battery auto-restore gate
        // (AC-601/602), decline warnings (AC-615~617), and manual-override
        // suppression (AC-618).
        batteryMonitor.$batteryPercentage
            .sink { [weak self] pct in
                self?.handleBatteryPercentageChange(pct)
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
    /// v0.2.6: records each AC/battery flip (AC-614), cancels in-flight
    /// restore on unplug (AC-613), and pauses the loop while a contact
    /// issue is pending.
    private func queuePowerAction(isOnBattery: Bool) {
        // Record an actual power flip. The initial app-list-load call reflects
        // the current state (not a transition) and must not count toward the
        // contact-issue threshold.
        if hasRecordedBatteryState, lastRecordedBatteryState != isOnBattery {
            recordPowerFlip()
        }
        lastRecordedBatteryState = isOnBattery
        hasRecordedBatteryState = true

        // Unplugging (battery) interrupts any in-flight restore sequence.
        if isOnBattery {
            processKiller.cancelRestore()
        }

        // Contact issue already pending: hold the loop until the user chooses.
        if contactIssue {
            powerActionContext?.debug("跳过: contactIssue 已置位，等待用户选择")
            return
        }

        // Detect a loose power connection (>= 3 flips within a 10s window).
        if isPowerContactIssue(flipTimes: powerFlipTimes, now: Date()) {
            contactIssue = true
            pendingPowerAction = nil
            powerActionContext?.log("⚠ 电源接触不良：\(powerFlipTimes.count) 次翻转/10s，停止自动循环")
            postSystemNotification(loc("Power contact unstable", "电源接触不良"))
            // Settings window visible -> SwiftUI `.alert`; closed (menu-bar-only
            // use) -> modal NSAlert fallback (design-spec §6.2), routed to main.
            if settingsWindow?.isVisible == true {
                showContactIssueDialog = true
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.presentContactIssueNSAlert()
                }
            }
            return
        }

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
        // Contact issue: block scheduling until the user resolves it (AC-614).
        guard !contactIssue else {
            powerActionContext?.debug("跳过: contactIssue 已置位，等待用户选择")
            return
        }

        pendingPowerAction = nil
        powerActionInProgress = true

        let ctx = powerActionContext ?? LogContext(name: "powerAction")
        let actionCtx = ctx.child(onBattery ? "killSelected" : "restoreKilledApps")
        actionCtx.log("开始执行 \(onBattery ? "终止" : "恢复") 操作")

        if onBattery {
            // Interrupt any in-flight restore before terminating (AC-612/613).
            processKiller.cancelRestore()
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
            // Auto restore on AC power -- gated by low battery (AC-601/602).
            if batteryMonitor.batteryPercentage < 20 {
                processKiller.restoreGateState = .delayedLowBattery
                processKiller.restoreGateReason = .lowBattery
                actionCtx.log("电量不足(<20%)，自动恢复延缓，待恢复列表保留")
                postSystemNotification(loc("Battery low, restore delayed (<20%)", "电量不足，恢复延缓（<20%）"))
                // No cooldown: the >=20% battery subscription resumes restore.
                powerActionInProgress = false
                syncLowBatteryGateTimer()
            } else {
                processKiller.restoreGateState = .idle
                processKiller.restoreSequential(using: appLister.apps, manual: false, context: actionCtx) { [weak self] in
                    self?.appLister.refreshAppList()
                    self?.onPowerActionCompleted(onBattery: onBattery)
                }
            }
        }
    }

    // MARK: - Restore Gating & Contact Issue (v0.2.6)

    /// Records an AC/battery flip timestamp and trims the sliding 10s window.
    private func recordPowerFlip() {
        let now = Date()
        powerFlipTimes.append(now)
        powerFlipTimes = powerFlipTimes.filter { $0 >= now.addingTimeInterval(-10) }
    }

    /// Handles a battery-percentage change: low-battery gating (AC-601/602),
    /// decline warnings (AC-615~617), and manual-override suppression (AC-618).
    ///
    /// Runs on the main thread (BatteryMonitor publishes on main). The
    /// auto-restore gate only affects the automatic path; manual restores
    /// (`manualRestoreOverride`) ignore all auto handling here.
    private func handleBatteryPercentageChange(_ pct: Double) {
        let now = Date()
        batterySnapshots.append((now, pct))
        batterySnapshots = batterySnapshots.filter { $0.time >= now.addingTimeInterval(-10) }

        // Manual restore running: ignore auto pause/gating (AC-618).
        guard !processKiller.manualRestoreOverride else { return }

        // Contact issue pending: hold all auto gate/restore decisions until the
        // user resolves the dialog (AC-614).
        guard !contactIssue else { return }

        // AC-617: below 20% while restoring on AC -> pause auto-restore.
        if shouldDelayAutoRestore(batteryPercentage: pct) {
            if !batteryMonitor.isOnBattery && processKiller.restoreGateState != .delayedLowBattery {
                processKiller.restoreGateState = .delayedLowBattery
                processKiller.restoreGateReason = .paused
                postSystemNotification(loc("Battery low, auto-restore paused", "电量不足，自动恢复已暂停"))
            }
            rapidDeclineNotified = false
            return
        }

        // AC-615/616: decline / rapid-decline over the sliding window. Only
        // meaningful while on AC (weak charger / high consumption during the
        // restore); on battery, natural drain is the expected state.
        let deltaStatus = analyzeBatteryDelta(
            snapshots: batterySnapshots, now: now,
            onAC: !batteryMonitor.isOnBattery)
        if deltaStatus.declining {
            // AC-615 is restore-context specific ("恢复后电量下降"): only pause
            // + notify "电源不足" when a restore is in progress or just finished.
            // An idle AC decline (weak charger, no restore) is the charger-
            // insufficient case (AC-619) and must NOT pause the gate (S5).
            let restoreContext = processKiller.isRestoring
                || processKiller.restoreGateState == .restoring
                || processKiller.restoreGateState == .completed
            if restoreContext && processKiller.restoreGateState != .delayedLowBattery {
                processKiller.restoreGateState = .delayedLowBattery
                processKiller.restoreGateReason = .paused
                postSystemNotification(loc("Insufficient power", "电源不足"))
            }
            if deltaStatus.rapidDecline && !rapidDeclineNotified {
                rapidDeclineNotified = true
                postSystemNotification(loc("Power consumption high — check connected apps", "消耗过大，建议处理"))
            }
            // AC-619: below 80% yet still draining while on AC -> the charger
            // cannot keep up; name the root cause and suggest a larger charger.
            if shouldWarnChargerPower(batteryPercentage: pct,
                                      onAC: !batteryMonitor.isOnBattery,
                                      declining: true)
                && !chargerPowerNotified {
                chargerPowerNotified = true
                postSystemNotification(loc("Charger power insufficient — use a higher power charger",
                                           "充电器功率不足，请更换更大功率的充电器进行充电"))
            }
        } else {
            rapidDeclineNotified = false
            chargerPowerNotified = false
        }

        // AC-602: gate cleared (>=20% on AC, not already restoring) -> resume
        // the auto-restore sequence. Routed through the power queue so the
        // restore respects the in-progress mutex and 30s cooldown (S4).
        if !batteryMonitor.isOnBattery && !shouldDelayAutoRestore(batteryPercentage: pct)
            && processKiller.restoreGateState == .delayedLowBattery
            && !processKiller.isRestoring {
            processKiller.restoreGateState = .idle
            postSystemNotification(loc("Battery sufficient, restore started", "电量充足，开始恢复"))
            queuePowerAction(isOnBattery: false)
        }
        syncLowBatteryGateTimer()
    }

    /// Starts or stops the low-battery gate polling timer (B1). The timer is
    /// active only while the gate is held (`.delayedLowBattery` on AC); it is
    /// invalidated as soon as the gate clears, the Mac unplugs, or a manual
    /// override engages, keeping idle power unaffected.
    private func syncLowBatteryGateTimer() {
        let shouldPoll = processKiller.restoreGateState == .delayedLowBattery
            && !batteryMonitor.isOnBattery
            && !processKiller.manualRestoreOverride
        if shouldPoll {
            guard lowBatteryGateTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.batteryMonitor.checkPowerState()
            }
            timer.tolerance = 5
            lowBatteryGateTimer = timer
        } else {
            lowBatteryGateTimer?.invalidate()
            lowBatteryGateTimer = nil
        }
    }

    /// Resolves the power contact-issue dialog choice (AC-614).
    ///
    /// - Parameter choice: `.pause` (safe default), `.ignore` (continue), or
    ///   `.stop` (cancel restore, stay stopped).
    func resolveContactIssue(_ choice: ContactIssueChoice) {
        contactIssue = false
        showContactIssueDialog = false
        rapidDeclineNotified = false
        // Clear the flip window so the dialog fires ONCE per episode, not
        // repeatedly: old flips stay in the 10s window and would re-trigger
        // immediately (esp. ".ignore", which re-runs queuePowerAction).
        powerFlipTimes = []
        switch choice {
        case .pause:
            processKiller.cancelRestore()
            processKiller.restoreGateState = .delayedLowBattery
            processKiller.restoreGateReason = .contactIssue
            logger("resolveContactIssue: 暂停恢复，待恢复列表保留")
        case .ignore:
            logger("resolveContactIssue: 忽略接触异常，继续恢复")
            // Route through the power queue (mutex/cooldown) and guard against
            // re-entry: the alert's dismiss binding and the button action may
            // both resolve, so never start a second sequence (S4/S6).
            if !processKiller.isRestoring {
                queuePowerAction(isOnBattery: false)
            }
        case .stop:
            processKiller.cancelRestore()
            logger("resolveContactIssue: 停止，保持停止状态")
        }
        syncLowBatteryGateTimer()
    }

    /// Posts a system (UNUserNotificationCenter) notification with the BatKill
    /// title. Used for gate / contact-issue status transitions (AC-609~611).
    private func postSystemNotification(_ body: String) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "BatKill"
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private func onPowerActionCompleted(onBattery: Bool) {
        powerActionInProgress = false

        let ctx = powerActionContext ?? LogContext(name: "powerAction")
        ctx.log("操作完成，启动 \(Int(powerActionDelaySeconds))s 冷却定时器")

        let msg = localizationManager.translate(
            "Cooldown: next action in \(Int(powerActionDelaySeconds))s",
            "冷却中：\(Int(powerActionDelaySeconds))秒后可执行下一操作")
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
