import Cocoa
import SwiftUI

/// Manages the NSStatusItem (menu‑bar icon), NSPopover, badge rendering, and context menu.
final class MenuBarManager: NSObject, ObservableObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    // ──────────────────────────────────────────────
    // MARK: - Init
    // ──────────────────────────────────────────────
    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        setupButton()
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "bolt.batteryblock", accessibilityDescription: "BatKill")
        button.action = #selector(handleClick)
        button.target = self
        // Receive both left and right clicks
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // ──────────────────────────────────────────────
    // MARK: - Popover content
    // ──────────────────────────────────────────────
    func setPopoverContent<V: View>(_ view: V) {
        let host = NSHostingController(rootView: view)
        popover.contentViewController = host
    }

    // ──────────────────────────────────────────────
    // MARK: - Click routing
    // ──────────────────────────────────────────────
    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        event.type == .rightMouseUp ? showContextMenu() : togglePopover()
    }

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
    // MARK: - Right‑click context menu
    // ──────────────────────────────────────────────
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
    // MARK: - Badge
    // ──────────────────────────────────────────────
    func updateBadge(count: Int) {
        guard let button = statusItem.button else { return }
        DispatchQueue.main.async {
            button.image = count > 0 ? self.renderBadgedIcon(count: count)
                                     : NSImage(systemSymbolName: "bolt.batteryblock",
                                               accessibilityDescription: "BatKill")
        }
    }

    /// Returns a menu‑bar icon with a red badge overlaid at the top‑right corner.
    private func renderBadgedIcon(count: Int) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let img = NSImage(size: size)

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

        // White text, integer‑aligned for crispness
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let ts = label.size(withAttributes: attrs)
        let tx = round(bx + (d - ts.width) / 2)
        let ty = round(by + (d - ts.height) / 2 - 0.5)
        label.draw(at: NSPoint(x: tx, y: ty), withAttributes: attrs)

        return img
    }

    // ──────────────────────────────────────────────
    // MARK: - Show settings window
    // ──────────────────────────────────────────────
    @objc func showSettingsWindow() {
        if popover.isShown { popover.performClose(nil) }
        NotificationCenter.default.post(name: .showSettings, object: nil)
    }
}

extension Notification.Name {
    static let showSettings = Notification.Name("showSettings")
    static let showTemperature = Notification.Name("showTemperature")
}

