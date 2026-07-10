import SwiftUI
import ServiceManagement
import Combine

// MARK: - App Entry Point
@main
struct BatKillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup(id: "settings") {
            ContentView()
                .environmentObject(appDelegate.batteryMonitor)
                .environmentObject(appDelegate.appLister)
                .environmentObject(appDelegate.processKiller)
                .environmentObject(appDelegate.localizationManager)
                .environmentObject(appDelegate.versionChecker)
                .environmentObject(appDelegate.updater)
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}

// MARK: - App Delegate
final class AppDelegate: NSObject, NSApplicationDelegate {
    let batteryMonitor      = BatteryMonitor()
    let appLister           = AppLister()
    let processKiller       = ProcessKiller()
    let localizationManager = LocalizationManager.shared
    let versionChecker      = VersionChecker()
    lazy var updater        = Updater(checker: versionChecker)

    private var menuBarManager: MenuBarManager?
    private var hasAppeared      = false
    private var settingsWindow: NSWindow?
    private var cancellables     = Set<AnyCancellable>()

    // ── Power‑action queue ──
    private var pendingPowerAction: Bool?     // nil=none, true=battery(kill), false=AC(restore)
    private var powerActionInProgress = false
    private var powerDelayTimer: Timer?
    private let powerActionDelaySeconds: TimeInterval = 5

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. Single-instance enforcement
        if enforceSingleInstance() { return }

        // 1. Menu bar
        let mgr = MenuBarManager()
        menuBarManager = mgr
        let pv = PopoverView(
            batteryMonitor: batteryMonitor, appLister: appLister,
            processKiller: processKiller, lm: localizationManager)
        mgr.setPopoverContent(pv)

        // 2. Start
        appLister.refreshAppList()

        // 3. Check for updates
        versionChecker.checkForUpdate()

        // 4. Listen for settings window requests
        NotificationCenter.default.addObserver(
            self, selector: #selector(showSettingsWindow),
            name: .showSettings, object: nil)

        // 4. Badge & state
        observeStateChanges()
    }

    @objc func showSettingsWindow() {
        logger("showSettingsWindow: called, settingsWindow=\(settingsWindow != nil), isVisible=\(settingsWindow?.isVisible ?? false)")

        if let win = settingsWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            activateApp()
            return
        }

        settingsWindow?.close()
        settingsWindow = nil

        let contentView = ContentView()
            .environmentObject(batteryMonitor)
            .environmentObject(appLister)
            .environmentObject(processKiller)
            .environmentObject(localizationManager)

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "BatKill"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 640))
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        activateApp()
    }

    private func activateApp() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Badge & state
    // ──────────────────────────────────────────────
    private func observeStateChanges() {
        batteryMonitor.$isOnBattery
            .sink { [weak self] newValue in
                guard let self = self, appLister.hasLoaded else { return }
                self.refreshBadge()
                self.queuePowerAction(isOnBattery: newValue)
            }
            .store(in: &cancellables)
        appLister.$apps
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)
        processKiller.$pendingRestoreCount
            .sink { [weak self] _ in self?.refreshBadge() }
            .store(in: &cancellables)
        appLister.$hasLoaded
            .sink { [weak self] loaded in
                guard loaded, let self = self, !self.hasAppeared else { return }
                self.hasAppeared = true
                self.refreshBadge()
                self.queuePowerAction(isOnBattery: batteryMonitor.isOnBattery)
            }
            .store(in: &cancellables)
    }

    private func refreshBadge() {
        guard appLister.hasLoaded else { return }
        let count = batteryMonitor.isOnBattery
            ? appLister.apps.filter { $0.isSelected && $0.isRunning }.count
            : processKiller.pendingRestoreCount
        menuBarManager?.updateBadge(count: count)
    }

    // ──────────────────────────────────────────────
    // MARK: - Power‑action queue
    // ──────────────────────────────────────────────
    private var autoKillEnabled: Bool { UserDefaults.standard.bool(forKey: "autoKillEnabled") }

    /// Enqueue a power‑state transition.
    /// Rapid successive calls coalesce — only the **latest** state is retained.
    private func queuePowerAction(isOnBattery: Bool) {
        logger("queuePowerAction: isOnBattery=\(isOnBattery) inProgress=\(powerActionInProgress) hasTimer=\(powerDelayTimer != nil) hadPending=\(pendingPowerAction != nil)")
        pendingPowerAction = isOnBattery
        processNextPowerAction()
    }

    /// Process the next queued action when idle and not in delay period.
    private func processNextPowerAction() {
        guard !powerActionInProgress, powerDelayTimer == nil, let onBattery = pendingPowerAction else {
            return
        }

        pendingPowerAction = nil
        powerActionInProgress = true
        logger("processNextPowerAction: executing for isOnBattery=\(onBattery)")

        if onBattery {
            if autoKillEnabled {
                processKiller.killSelected(appLister.apps) { [weak self] in
                    self?.onPowerActionCompleted()
                }
            } else {
                onPowerActionCompleted()
            }
        } else {
            processKiller.restoreKilledApps(using: appLister.apps) { [weak self] in
                self?.onPowerActionCompleted()
            }
        }
    }

    /// Called on main thread when the current kill/restore finishes or is skipped.
    private func onPowerActionCompleted() {
        powerActionInProgress = false
        logger("onPowerActionCompleted: pending=\(pendingPowerAction != nil), starting \(powerActionDelaySeconds)s delay")

        guard pendingPowerAction != nil else { return }

        powerDelayTimer = Timer.scheduledTimer(withTimeInterval: powerActionDelaySeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.powerDelayTimer = nil
            logger("onPowerActionCompleted: delay ended, processing next")
            self.processNextPowerAction()
        }
    }
}
