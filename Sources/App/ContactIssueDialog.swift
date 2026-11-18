//  ContactIssueDialog.swift
//  BatKill
//
//  Power contact-issue prompt (design-spec §6.2, AC-614). While the settings
//  window is visible the prompt is a SwiftUI `.alert` bound to
//  `AppDelegate.showContactIssueDialog`; in menu-bar-only use (window closed)
//  `presentContactIssueNSAlert` shows a modal NSAlert with the same choices,
//  mapped 1:1 to `resolveContactIssue`.
//
//  The prompt content follows the FINAL power state at the end of the
//  detection window (真机反馈): on battery power auto-restore is meaningless —
//  restore only runs on AC — so the battery variant never asks "continue
//  restore"; the user relaunches what they need manually.
//
//  Only one dialog per episode: `AppDelegate` suppresses detection for
//  `ContactIssuePrompt.cooldown` after a prompt fires.

import AppKit

/// Contact-issue prompt content, selected purely by the final power state so
/// the branching is unit-testable without presenting any UI.
enum ContactIssuePrompt {
    /// How long detection is suppressed after a prompt fires, so a still-
    /// flapping connection pops at most one dialog per episode (弹窗不要多个).
    static let cooldown: TimeInterval = 60

    /// Choices offered, in order. Battery (离电) drops the restore options.
    static func choices(onBattery: Bool) -> [ContactIssueChoice] {
        onBattery ? [.ignore, .stop] : [.pause, .ignore, .stop]
    }

    /// Button label for a choice. `.ignore` reads differently on battery, where
    /// there is no restore sequence to continue.
    static func title(_ choice: ContactIssueChoice, onBattery: Bool) -> String {
        switch choice {
        case .pause: return loc("Pause restore", "暂停恢复")
        case .ignore:
            return onBattery
                ? loc("Ignore & continue", "忽略异常，继续")
                : loc("Ignore & continue restore", "继续忽略异常，继续恢复")
        case .stop: return loc("Stop", "停止")
        }
    }

    /// Dialog body. On battery it states that restore is manual.
    static func informative(onBattery: Bool) -> String {
        onBattery
            ? loc("Repeated power switching detected — possible loose contact. "
                + "Currently on battery power: BatKill will not restore "
                + "terminated apps automatically, relaunch what you need.",
                "检测到电源反复切换，可能接触不良。当前为电池供电：不会自动恢复已终止的软件，请手动启动需要的软件。")
            : loc("Repeated power switching detected — possible loose contact",
                  "检测到电源反复切换，可能接触不良")
    }
}

extension AppDelegate {
    /// Presents the contact-issue prompt for the FINAL power state, routing to
    /// the SwiftUI `.alert` when the settings window is visible and to a single
    /// modal NSAlert otherwise — never both.
    func presentContactIssue(onBattery: Bool) {
        contactIssueOnBattery = onBattery
        if settingsWindow?.isVisible == true {
            showContactIssueDialog = true
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.presentContactIssueNSAlert(onBattery: onBattery)
            }
        }
    }

    /// Modal NSAlert fallback for menu-bar-only use. `runModal` blocks the UI
    /// loop until the user chooses, which is the intended modal behavior for
    /// this rare, must-respond state. Buttons follow the final power state and
    /// map 1:1 to `resolveContactIssue`.
    func presentContactIssueNSAlert(onBattery: Bool) {
        let alert = NSAlert()
        alert.messageText = loc("Power contact unstable", "电源接触不良")
        alert.informativeText = ContactIssuePrompt.informative(onBattery: onBattery)
        let choices = ContactIssuePrompt.choices(onBattery: onBattery)
        for choice in choices {
            alert.addButton(withTitle: ContactIssuePrompt.title(choice, onBattery: onBattery))
        }
        // ModalResponse.rawValue: 1000 = first button, 1001 = second, and so on.
        let response = alert.runModal()
        let index = max(0, response.rawValue - 1000)
        resolveContactIssue(choices[min(index, choices.count - 1)])
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
