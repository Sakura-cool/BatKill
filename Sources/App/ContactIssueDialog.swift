//  ContactIssueDialog.swift
//  BatKill
//
//  Power contact-issue prompt (design-spec §6.2, AC-614). Always one
//  standalone modal NSAlert — never a SwiftUI `.alert` bound to the settings
//  window (CHANGE-082): that route tied presentation to the host window's
//  visible/key state, which for this LSUIElement (no-Dock) app could leave a
//  must-respond prompt unpresented, and left a stale flag behind when the
//  window closed mid-prompt. Choices come from `ContactIssuePrompt` and map
//  1:1 to `resolveContactIssue`.
//
//  While the prompt is open it is watched live (CHANGE-083): an unplug that
//  holds for `ContactIssuePrompt.unplugConfirmDelay` (5s, guarding against a
//  loose/flapping connector misreading as a real unplug) re-presents it with a
//  single acknowledgement, because restore only ever runs on AC.
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

    /// How long an unplug must persist while the prompt is open before it degrades
    /// to a single acknowledgement (CHANGE-083). An immediate read is
    /// unreliable under a loose/flapping connector (虚接), so a real unplug is
    /// only trusted once it holds for this long.
    static let unplugConfirmDelay: TimeInterval = 5

    /// Choices offered, in order. Battery (离电) drops the restore options.
    static func choices(onBattery: Bool) -> [ContactIssueChoice] {
        onBattery ? [.ignore, .stop] : [.pause, .ignore, .stop]
    }

    /// Choices for the degraded prompt (CHANGE-083): power was unplugged while it
    /// was open, so every restore choice is meaningless and a single
    /// acknowledgement is offered. Maps to `.pause`, the safe default.
    static func degradedChoices() -> [ContactIssueChoice] { [.pause] }

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

    /// Reuses the existing `OK / 知道了` key — no new localization surface
    /// (CHANGE-083).
    static func degradedTitle() -> String { loc("OK", "知道了") }

    /// Body for the degraded prompt: states that the power was unplugged while
    /// it was open (CHANGE-083).
    static func degradedInformative() -> String {
        loc("Power was unplugged while this dialog was open. The restore sequence "
            + "has stopped — relaunch what you need manually.",
            "弹窗期间检测到电源已断开，恢复已中止——请手动启动需要的软件。")
    }
}

extension AppDelegate {
    /// Presents the contact-issue prompt for the FINAL power state as a single
    /// standalone modal NSAlert, regardless of whether the settings window is
    /// open (CHANGE-082).
    func presentContactIssue(onBattery: Bool) {
        contactIssueOnBattery = onBattery
        DispatchQueue.main.async { [weak self] in
            self?.presentContactIssueNSAlert(onBattery: onBattery)
        }
    }

    /// Standalone modal NSAlert. `runModal` blocks the UI loop until the user
    /// chooses — the intended modal behavior for this rare, must-respond state.
    ///
    /// While it is open, an unplug that PERSISTS for `unplugConfirmDelay` (5s)
    /// re-presents it degraded to a single acknowledgement (CHANGE-083): restore
    /// only ever runs on AC, so every restore choice is then meaningless. The
    /// 5s hold avoids a false positive from a loose/flapping connector (虚接) —
    /// an immediate read would degrade spuriously.
    func presentContactIssueNSAlert(onBattery: Bool) {
        var promptOnBattery = onBattery
        var degraded = false
        while true {
            var superseded = false
            var presenting = false
            var unplugSince: Date?
            // `.common` modes include the modal-panel mode, so the watch keeps
            // firing while `runModal` blocks the main thread.
            let unplugWatch = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, presenting, !superseded, !promptOnBattery else { return }
                // Read IOKit directly rather than trusting the IOKit async
                // dispatch, which may not be drained while the modal session owns
                // the run loop.
                self.batteryMonitor.checkPowerState()
                guard self.batteryMonitor.isOnBattery else {
                    // Back on AC within the window: contact chatter (虚接), not a
                    // real unplug — restart the confirmation.
                    unplugSince = nil
                    return
                }
                let since = unplugSince ?? Date()
                unplugSince = since
                guard Date().timeIntervalSince(since) >= ContactIssuePrompt.unplugConfirmDelay
                else { return }
                superseded = true
                self.contactIssueOnBattery = true
                logger("contactIssue: 弹窗期间拔电已持续 "
                    + "\(Int(ContactIssuePrompt.unplugConfirmDelay))s，降级为单按钮「知道了」")
                NSApp.stopModal()
            }
            RunLoop.main.add(unplugWatch, forMode: .common)

            let (alert, choices) = contactIssueAlert(onBattery: promptOnBattery, degraded: degraded)
            // Bring BatKill to the foreground before the modal loop: the app is
            // LSUIElement (no Dock icon), so presenting from the background would
            // leave the alert hidden behind the frontmost app — and this prompt
            // is must-respond.
            NSApp.activate()
            presenting = true
            // ModalResponse.rawValue: 1000 = first button, 1001 = second, and so on.
            let response = alert.runModal()
            presenting = false
            unplugWatch.invalidate()

            guard !superseded else {
                degraded = true
                promptOnBattery = true
                continue
            }
            // Esc / Cmd-. dismisses with NSModalResponse.abort (rawValue -1000),
            // not a button index. Treat it as the safe default — pause restore,
            // matching the passive-dismissal behavior of the old SwiftUI `.alert`.
            if response == .abort {
                resolveContactIssue(.pause)
                break
            }
            let index = max(0, response.rawValue - 1000)
            resolveContactIssue(choices[min(index, choices.count - 1)])
            break
        }
    }

    /// Builds the prompt alert for one presentation. `degraded` is the live-
    /// unplug variant (CHANGE-083). Returns the alert with its choice set so the
    /// button response maps back 1:1.
    private func contactIssueAlert(onBattery: Bool, degraded: Bool)
        -> (NSAlert, [ContactIssueChoice]) {
        let alert = NSAlert()
        alert.messageText = loc("Power contact unstable", "电源接触不良")
        let choices = degraded
            ? ContactIssuePrompt.degradedChoices()
            : ContactIssuePrompt.choices(onBattery: onBattery)
        alert.informativeText = degraded
            ? ContactIssuePrompt.degradedInformative()
            : ContactIssuePrompt.informative(onBattery: onBattery)
        for choice in choices {
            alert.addButton(withTitle: degraded
                ? ContactIssuePrompt.degradedTitle()
                : ContactIssuePrompt.title(choice, onBattery: onBattery))
        }
        return (alert, choices)
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
