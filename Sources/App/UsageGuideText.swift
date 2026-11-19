//  UsageGuideText.swift
//  BatKill
//
//  Body of the in-app usage guide shown by the settings window's help button.
//  Extracted from `AppDelegate` (which hit SwiftLint's 1000-line file_length
//  gate) and kept alongside the other App-layer presentation helpers.
//
//  Mirrors docs/USAGE.md minus the installation section — the app is already
//  installed when this guide is reachable.

import AppKit

extension AppDelegate {
    /// Compact usage-guide body: battery saver, power contact issues, fan
    /// control, presets, and the temperature threshold guard.
    func usageGuideText() -> String {
        localizationManager.translate(
            "Battery saver:\n"
            + "1. Click the menu-bar battery icon → Settings\n"
            + "2. Tick apps to auto-stop on battery\n"
            + "3. Unplug → apps close after 30s; replug → they restore\n"
            + "\n"
            + "Power contact issues:\n"
            + "If power flips 3+ times within 10s, a standalone dialog asks you to "
            + "pause / ignore & continue / stop. On battery there is nothing to "
            + "continue, so only ignore or stop is offered. Unplug while it is open "
            + "and it collapses to a single OK after 5s.\n"
            + "BatKill never lists itself: suspending itself would freeze the very "
            + "code that must resume your apps.\n\n"
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
            + "3. 拔电源 → 30 秒后自动关闭；插回 → 自动恢复\n"
            + "\n"
            + "电源接触不良：\n"
            + "10 秒内电源翻转 ≥3 次会弹出独立对话框，让你选择\n"
            + "「暂停恢复 / 继续忽略异常，继续恢复 / 停止」；电池供电时不提供\n"
            + "「继续恢复」（恢复只发生在接电）。弹窗期间拔电持续 5 秒后\n"
            + "收敛为单一「知道了」。\n"
            + "列表中不含 BatKill 自身：挂起自身会冻结负责恢复的程序本身。\n\n"
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
}
