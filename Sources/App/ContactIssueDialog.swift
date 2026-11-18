//  ContactIssueDialog.swift
//  BatKill
//
//  No-window fallback for the power contact-issue dialog (design-spec §6.2,
//  AC-614): the contact-issue prompt is a SwiftUI `.alert` bound to
//  `AppDelegate.showContactIssueDialog`, which is presented only while the
//  settings window is visible. In menu-bar-only use (window closed) that
//  `.alert` cannot present, so this extension provides a modal NSAlert with
//  the same three choices, mapped 1:1 to `resolveContactIssue`.

import AppKit

extension AppDelegate {
    /// Presents the contact-issue dialog as a modal NSAlert (no-window
    /// fallback). Called on the main thread (dispatched from
    /// `queuePowerAction`); `runModal` blocks the UI loop until the user
    /// chooses, which is the intended modal behavior for this rare,
    /// must-respond state. Buttons map to `resolveContactIssue`:
    /// Pause (safe default) / Ignore & continue / Stop.
    func presentContactIssueNSAlert() {
        let alert = NSAlert()
        alert.messageText = loc("Power contact unstable", "电源接触不良")
        alert.informativeText = loc(
            "Repeated power switching detected — possible loose contact",
            "检测到电源反复切换，可能接触不良")
        alert.addButton(withTitle: loc("Pause restore", "暂停恢复"))
        alert.addButton(withTitle: loc("Ignore & continue restore", "继续忽略异常，继续恢复"))
        alert.addButton(withTitle: loc("Stop", "停止"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: resolveContactIssue(.pause)
        case .alertSecondButtonReturn: resolveContactIssue(.ignore)
        default: resolveContactIssue(.stop)
        }
    }

    /// Appends the charger's rated power and the current whole-system power
    /// draw to a state-change notification body (AC-620), so the user can see
    /// how much headroom the connected charger has. When the charger is small
    /// (tight headroom, <8W above the current draw — the same tier that
    /// lengthens `powerRestoreInterval`), appends a hint that restore time is
    /// extended. Degrades gracefully (returns `body` unchanged) when the
    /// AppleSmartBattery registry is unavailable, e.g. on battery power.
    func powerHintBody(_ body: String) -> String {
        let reader = PowerLoadReader()
        guard let charger = reader.chargerWatts(),
              let power = reader.currentPowerWatts() else {
            return body
        }
        let base = body + "\n" + localizationManager.translate(
            "Charger: \(Int(charger))W max · Using: \(Int(power))W",
            "充电器最大功率：\(Int(charger))W · 当前使用：\(Int(power))W")
        if charger - power < 8 {
            return base + "\n" + localizationManager.translate(
                "Low charger power — restore time extended",
                "充电器功率较小，恢复时间将延长")
        }
        return base
    }
}
