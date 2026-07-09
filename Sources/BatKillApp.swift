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
                .onAppear {
                    DispatchQueue.main.async {
                        NSApp.windows.first?.identifier = NSUserInterfaceItemIdentifier("BatKillWindow")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .showSettings)) { _ in
                    if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "BatKillWindow" }) {
                        win.makeKeyAndOrderFront(nil)
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
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

    private var menuBarManager: MenuBarManager?
    private var hasAppeared      = false
    private var windowAllowed    = false   // true = user clicked "Show Window"
    private var cancellables     = Set<AnyCancellable>()

    // ──────────────────────────────────────────────
    // MARK: - Launch
    // ──────────────────────────────────────────────
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Menu bar
        let mgr = MenuBarManager()
        menuBarManager = mgr
        let pv = PopoverView(
            batteryMonitor: batteryMonitor, appLister: appLister,
            processKiller: processKiller, lm: localizationManager)
        mgr.setPopoverContent(pv)

        // 2. Start
        appLister.refreshAppList()

        // 3. Suppress the automatic window that SwiftUI WindowGroup creates
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeVisible),
            name: Notification.Name("NSWindowDidBecomeVisibleNotification"), object: nil)

        // 4. Badge & state
        observeStateChanges()
    }

    // ──────────────────────────────────────────────
    // MARK: - Window suppression
    // ──────────────────────────────────────────────
    @objc private func windowDidBecomeVisible(_ n: Notification) {
        guard let win = n.object as? NSWindow,
              win.identifier?.rawValue == "BatKillWindow",
              !windowAllowed else { return }
        win.close()
    }

    /// Called from the menu‑bar context menu / popover.
    @objc func showSettingsWindow() {
        windowAllowed = true
        NotificationCenter.default.post(name: .showSettings, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.windowAllowed = false
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Badge & state
    // ──────────────────────────────────────────────
    private func observeStateChanges() {
        batteryMonitor.$isOnBattery
            .sink { [weak self] _ in self?.refreshBadge(); self?.handlePowerTransition() }
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
                self.handleInitialState()
            }
            .store(in: &cancellables)
    }

    private func refreshBadge() {
        guard appLister.hasLoaded else { return }
        let count = batteryMonitor.isOnBattery
            ? processKiller.pendingRestoreCount
            : appLister.apps.filter { $0.isSelected && $0.isRunning }.count
        menuBarManager?.updateBadge(count: count)
    }

    // ──────────────────────────────────────────────
    // MARK: - Power / initial logic
    // ──────────────────────────────────────────────
    private var autoKillEnabled: Bool { UserDefaults.standard.bool(forKey: "autoKillEnabled") }

    private func handleInitialState() {
        if batteryMonitor.isOnBattery {
            if autoKillEnabled { processKiller.killSelected(appLister.apps) }
        } else {
            processKiller.restoreKilledApps(using: appLister.apps)
        }
    }

    private func handlePowerTransition() {
        guard appLister.hasLoaded else { return }
        if batteryMonitor.isOnBattery {
            if autoKillEnabled { processKiller.killSelected(appLister.apps) }
        } else {
            processKiller.restoreKilledApps(using: appLister.apps)
        }
    }
}
