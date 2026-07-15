//  MenuBarManager.swift
//  BatKill
//
//  Manages the NSStatusItem (menu-bar icon), the popover panel that appears
//  on left-click, the right-click context menu, badge rendering with a
//  red count overlay, and brief tooltip notifications under the menu bar.
//
//  This is the lowest-level UI layer of BatKill. It has no knowledge of
//  SwiftUI environment objects — it receives views via setPopoverContent()
//  and receives badge updates via updateBadge().
//
//  Architecture:
//    - Created once by AppDelegate.applicationDidFinishLaunching()
//    - Owns the NSStatusItem and an NSPanel-based popover
//    - Routes left-click to togglePopover(), right-click to showContextMenu()
//    - Badge rendering is done via CoreGraphics into an NSImage
//    - Notifications are rendered as a borderless NSPanel positioned below
//      the status-item button
//
//  Popover approach:
//    Uses a custom NSPanel (not NSPopover) for the popover, manually
//    positioned below the status-item button. This avoids NSPopover's
//    unreliable positioning across macOS versions — the panel is placed
//    directly using the button's window frame in screen coordinates.
//    A local event monitor detects clicks outside the panel to dismiss it.

import Cocoa
import SwiftUI

// MARK: - Menu Bar Manager

/// Manages the NSStatusItem (menu-bar icon), popover panel, badge rendering,
/// and context menu for the BatKill menu-bar agent.
final class MenuBarManager: NSObject, ObservableObject {

    /// The system status item pinned to the menu bar.
    private let statusItem: NSStatusItem

    /// Stored SwiftUI view, set once at launch.
    private var popoverView: (any View)?

    /// The popover panel and its hosting controller, created lazily on first
    /// click and destroyed on close. Keeping either alive while hidden causes
    /// AppKit to run display-cycle layout passes on the SwiftUI hierarchy.
    private var popoverPanel: NSPanel? = nil
    private var hostingController: NSHostingController<AnyView>? = nil

    /// Monitors clicks outside the popover panel to dismiss it.
    private var eventMonitor: Any?

    // ──────────────────────────────────────────────
    // MARK: - Rapid Click Detection (Debug Toggle)
    // ──────────────────────────────────────────────

    /// Timestamps of recent left-clicks for rapid-click detection.
    private var clickTimestamps: [Date] = []

    /// Number of clicks required to toggle debug logging.
    private let requiredClicks = 5

    /// Time window (seconds) within which clicks must occur.
    private let clickWindow: TimeInterval = 2.0

    /// Callback invoked when rapid-click gesture is detected.
    var onRapidClickDetected: (() -> Void)?

    // ──────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────

    /// Creates the status item and configures the button to receive
    /// both left and right mouse events. The popover panel is NOT created
    /// here — it is created lazily on the first left-click.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        setupButton()
    }

    /// Configures the status-item button with the SF Symbol icon and
    /// action handler. Sets up left+right click routing.
    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bolt.batteryblock", accessibilityDescription: "BatKill")
        button.action = #selector(handleClick)
        button.target = self
        // Receive both left and right clicks
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // ──────────────────────────────────────────────
    // MARK: - Popover Content
    // ──────────────────────────────────────────────

    /// Stores the SwiftUI view for later use. The `NSHostingController` is
    /// NOT created here — it is created lazily in `togglePopover()` when the
    /// popover is shown and destroyed when it closes. This avoids AppKit
    /// display-cycle layout overhead on the SwiftUI hierarchy while the
    /// popover is hidden.
    func setPopoverContent<V: View>(_ view: V) {
        popoverView = view
    }

    // ──────────────────────────────────────────────
    // MARK: - Click Routing
    // ──────────────────────────────────────────────

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            recordClick()
            togglePopover()
        }
    }

    /// Records a left-click timestamp and checks for rapid-click gesture.
    private func recordClick() {
        let now = Date()
        clickTimestamps.append(now)

        // Remove clicks outside the time window
        clickTimestamps = clickTimestamps.filter { now.timeIntervalSince($0) <= clickWindow }

        // Check if we have enough clicks within the window
        if clickTimestamps.count >= requiredClicks {
            clickTimestamps.removeAll()
            onRapidClickDetected?()
        }
    }

    // ──────────────────────────────────────────────
    // MARK: - Panel Popover (window-based, not NSPopover)
    // ──────────────────────────────────────────────

    /// Shows or hides the popover panel, anchored directly below the
    /// status-item button using screen coordinates. The NSPanel and
    /// NSHostingController are created on first show and destroyed on
    /// close to avoid AppKit display-cycle overhead while hidden.
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if let panel = popoverPanel, panel.isVisible {
            closePopoverPanel()
        } else {
            showPopoverPanel(from: button)
        }
    }

    /// Creates (if needed) and shows the popover panel positioned just
    /// below the status-item button.
    private func showPopoverPanel(from button: NSButton) {
        guard let view = popoverView else { return }

        // ── Lazily create the panel ──
        if popoverPanel == nil {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.level = .statusBar
            panel.hasShadow = true
            panel.isMovable = false
            panel.collectionBehavior = [.transient, .ignoresCycle, .moveToActiveSpace]

            // ── Vibrancy background (matches NSPopover look) ──
            let effectView = NSVisualEffectView()
            effectView.material = .hudWindow
            effectView.state = .active
            effectView.blendingMode = .behindWindow
            effectView.isEmphasized = true
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = 10
            effectView.layer?.masksToBounds = true
            panel.contentView = effectView

            // ── Host the SwiftUI view on top of the vibrancy ──
            let hosting = NSHostingController(rootView: AnyView(view))
            hosting.view.wantsLayer = true
            effectView.addSubview(hosting.view)
            hostingController = hosting

            // Size the panel from the SwiftUI view's fitting size
            let contentSize = hosting.view.fittingSize
            hosting.view.frame = NSRect(origin: .zero, size: contentSize)
            effectView.frame = NSRect(origin: .zero, size: contentSize)
            panel.setContentSize(contentSize)

            popoverPanel = panel

            // ── Event monitor: close on click outside (global) ──
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
                [weak self] event in
                guard let self = self,
                      let panel = self.popoverPanel,
                      panel.isVisible,
                      let button = self.statusItem.button,
                      let btnWindow = button.window
                else { return }

                let screenPoint = NSEvent.mouseLocation

                // Don't close if click is on the status item button itself
                let btnFrame = btnWindow.frame
                let isOnButton = btnFrame.contains(screenPoint)
                let isOnPanel = panel.frame.contains(screenPoint)

                if !isOnButton && !isOnPanel {
                    DispatchQueue.main.async {
                        self.closePopoverPanel()
                    }
                }
            }
        }

        guard let panel = popoverPanel else { return }

        // ── Position the panel just below the status-item button ──
        if let buttonWindow = button.window {
            let btnFrame = buttonWindow.frame   // Screen coordinates of the menu-bar button
            let panelSize = panel.frame.size
            let panelX = btnFrame.midX - panelSize.width / 2
            // btnFrame.minY = bottom edge of the menu bar (top of screen minus menu bar height)
            let panelY = btnFrame.minY - panelSize.height - 6
            panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
        }

        panel.orderFront(nil)
        panel.makeKey()
    }

    /// Closes and destroys the popover panel, releasing all resources.
    private func closePopoverPanel() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        popoverPanel?.close()
        popoverPanel = nil
        hostingController = nil
    }

    // ──────────────────────────────────────────────
    // MARK: - Right-Click Context Menu
    // ──────────────────────────────────────────────

    /// Displays a context menu below the status-item button with
    /// "Show Window" and "Quit" items.
    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        let showItem = menu.addItem(withTitle: loc("Show Window", "显示窗口"),
                                     action: #selector(showSettingsWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(NSMenuItem.separator())
        let quitItem = menu.addItem(withTitle: loc("Quit", "退出"),
                                     action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        let point = NSPoint(x: 0, y: button.bounds.height + 5)
        menu.popUp(positioning: nil, at: point, in: button)
    }

    // ──────────────────────────────────────────────
    // MARK: - Badge Rendering
    // ──────────────────────────────────────────────

    /// Updates the menu-bar icon to show a red badge with the given count.
    /// When count is 0, shows the plain icon without a badge.
    /// Must be called on the main thread.
    private var lastBadgeCount: Int = -1

    func updateBadge(count: Int) {
        guard count != lastBadgeCount else { return }
        lastBadgeCount = count
        debugLog("[MenuBar] 更新角标: \(count)")
        
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async {
            button.image = count > 0 ? self.renderBadgedIcon(count: count)
                                     : NSImage(systemSymbolName: "bolt.batteryblock",
                                               accessibilityDescription: "BatKill")
        }
    }

    /// Returns a menu-bar icon with a red badge overlaid at the top-right corner.
    /// The badge shows the count (capped at 99) as white text on a red circle
    /// with a white border for visibility against both light and dark menu bars.
    private func renderBadgedIcon(count: Int) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let img = NSImage(size: size)

        // Determine if the menu bar is in dark mode for tinting
        let isDark: Bool
        if #available(macOS 14.0, *) {
            isDark = statusItem.button?.effectiveAppearance.name == .darkAqua
        } else {
            isDark = false
        }

        img.lockFocusFlipped(false)
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        // ── Base SF Symbol ──
        // Render the bolt.batteryblock icon and tint it based on appearance
        let base = NSImage(systemSymbolName: "bolt.batteryblock", accessibilityDescription: nil)!
        var baseRect = CGRect(origin: .zero, size: size)
        if let cg = base.cgImage(forProposedRect: &baseRect, context: nil, hints: nil) {
            ctx.saveGState()
            let tint = isDark ? CGColor(gray: 1, alpha: 0.85) : CGColor(gray: 0.18, alpha: 0.85)
            ctx.setFillColor(tint)
            ctx.clip(to: baseRect, mask: cg)
            ctx.fill(baseRect)
            ctx.restoreGState()
        }

        // ── Badge ──
        // Red circle with white border and white numeric label
        let label = "\(min(count, 99))" as NSString
        let d: CGFloat = 14                     // badge diameter
        let mx: CGFloat = 1                     // outer margin
        let bx = size.width - d - mx
        let by = size.height - d - mx
        let bRect = CGRect(x: bx, y: by, width: d, height: d)

        // Red fill
        ctx.setFillColor(CGColor(red: 1, green: 0.22, blue: 0.18, alpha: 1))
        ctx.fillEllipse(in: bRect)
        // White border
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.85))
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: bRect.insetBy(dx: 0.5, dy: 0.5))

        // White text, integer-aligned for crispness
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let ts = label.size(withAttributes: attrs)
        let tx = round(bx + (d - ts.width) / 2)
        let ty = round(by + (d - ts.height) / 2 - 0.5)
        label.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)

        return img
    }

    // ──────────────────────────────────────────────
    // MARK: - Show Settings Window
    // ──────────────────────────────────────────────

    /// Closes the popover panel (if open) and posts the .showSettings
    /// notification to tell AppDelegate to open the settings window.
    @objc func showSettingsWindow() {
        closePopoverPanel()
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }

    // ──────────────────────────────────────────────
    // MARK: - Brief Notification
    // ──────────────────────────────────────────────

    /// Reference to the currently-displayed notification window so it
    /// can be closed before showing a new one.
    private var notificationWindow: NSWindow?

    /// Shows a brief tooltip-style notification below the menu-bar icon.
    /// The notification is a borderless NSPanel with a dark background
    /// and white text. It auto-dismisses after `duration` seconds.
    func showBriefNotification(_ message: String, duration: TimeInterval = 10) {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.notificationWindow?.close()

            let label = NSTextField(labelWithString: message)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.backgroundColor = NSColor(white: 0.15, alpha: 0.92)
            label.isBezeled = false
            label.isEditable = false
            label.alignment = .center
            label.sizeToFit()

            let padding: CGFloat = 12
            let contentSize = NSSize(
                width: label.frame.width + padding * 2,
                height: label.frame.height + padding * 2)
            label.frame.origin = NSPoint(x: padding, y: padding)

            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = 6
            panel.contentView?.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.92).cgColor
            panel.contentView?.addSubview(label)
            panel.contentView?.frame = NSRect(origin: .zero, size: contentSize)
            panel.setContentSize(contentSize)

            if let btnFrame = button.window?.frame {
                let panelX = btnFrame.midX - contentSize.width / 2
                let panelY = btnFrame.minY - contentSize.height - 6
                panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
            }

            let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(self.notificationClicked))
            panel.contentView?.addGestureRecognizer(clickGesture)

            panel.orderFront(nil)
            self.notificationWindow = panel

            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.dismissNotification()
            }
        }
    }

    @objc private func notificationClicked() {
        dismissNotification()
    }

    private func dismissNotification() {
        guard notificationWindow != nil else { return }
        notificationWindow?.close()
        notificationWindow = nil
    }
}

// Notification.Name extensions are defined centrally in Core/Extensions.swift
