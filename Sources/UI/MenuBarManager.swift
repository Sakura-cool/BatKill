//  MenuBarManager.swift
//  BatKill
//
//  Manages the NSStatusItem (menu-bar icon), the NSPopover that appears
//  on left-click, the right-click context menu, badge rendering with a
//  red count overlay, and brief tooltip notifications under the menu bar.
//
//  This is the lowest-level UI layer of BatKill. It has no knowledge of
//  SwiftUI environment objects -- it receives views via setPopoverContent()
//  and receives badge updates via updateBadge().
//
//  Architecture:
//    - Created once by AppDelegate.applicationDidFinishLaunching()
//    - Owns the NSStatusItem and NSPopover
//    - Routes left-click to togglePopover(), right-click to showContextMenu()
//    - Badge rendering is done via CoreGraphics into an NSImage
//    - Notifications are rendered as a borderless NSPanel positioned below
//      the status-item button

import Cocoa
import SwiftUI

// MARK: - Menu Bar Manager

/// Manages the NSStatusItem (menu-bar icon), NSPopover, badge rendering,
/// and context menu for the BatKill menu-bar agent.
final class MenuBarManager: NSObject, ObservableObject {

    /// The system status item pinned to the menu bar.
    private let statusItem: NSStatusItem

    /// The popover shown on left-click of the menu-bar icon.
    private let popover = NSPopover()

    // ──────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────

    /// Creates the status item and configures the button to receive
    /// both left and right mouse events.
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
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

    /// Sets the SwiftUI view displayed inside the popover. The view is
    /// wrapped in an NSHostingController.
    func setPopoverContent<V: View>(_ view: V) {
        let host = NSHostingController(rootView: view)
        popover.contentViewController = host
    }

    // ──────────────────────────────────────────────
    // MARK: - Click Routing
    // ──────────────────────────────────────────────

    /// Called by the status-item button action. Inspects the current
    /// NSEvent to determine left-click (toggle popover) vs right-click
    /// (show context menu).
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        event.type == .rightMouseUp ? showContextMenu() : togglePopover()
    }

    /// Shows or hides the popover, anchored to the status-item button.
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
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
    func updateBadge(count: Int) {
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

    /// Closes the popover (if open) and posts the .showSettings notification
    /// to tell AppDelegate to open the settings window.
    @objc func showSettingsWindow() {
        if popover.isShown { popover.performClose(nil) }
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
    func showBriefNotification(_ message: String, duration: TimeInterval = 3) {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Close any existing notification
            self.notificationWindow?.close()

            // Create the label
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

            // Create a borderless, non-activating panel
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

            // Position below the status-item button, centered horizontally
            if let btnFrame = button.window?.frame {
                let panelX = btnFrame.midX - contentSize.width / 2
                let panelY = btnFrame.minY - contentSize.height - 6
                panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
            }

            panel.orderFront(nil)
            self.notificationWindow = panel

            // Auto-dismiss after the specified duration
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                self?.notificationWindow?.close()
                self?.notificationWindow = nil
            }
        }
    }
}

// Notification.Name extensions are defined centrally in Core/Extensions.swift
