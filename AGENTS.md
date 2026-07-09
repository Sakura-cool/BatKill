# BatKill — 项目知识库

**生成日期:** 2026-07-09
**技术栈:** Swift 5 / SwiftUI / AppKit / IOKit / Combine
**目标系统:** macOS 14.0+ (arm64 + x86_64)
**Bundle ID:** com.batkill.app

## 概述

菜单栏常驻工具，电池供电时自动终止用户勾选的软件，接入交流电时自动恢复被杀掉的软件。单一职责的电源状态守护进程。

## 目录结构

```
BatKill/
├── Sources/
│   ├── BatKillApp.swift      # @main 入口, AppDelegate, 电源动作队列
│   ├── BatteryMonitor.swift  # IOKit 电源状态监听器
│   ├── ProcessKiller.swift   # 停止/恢复逻辑、持久化、通知
│   ├── AppLister.swift       # 发现应用、启动代理、后台服务
│   ├── ContentView.swift     # 设置窗口 (SwiftUI)
│   ├── PopoverView.swift     # 菜单栏弹窗
│   ├── MenuBarManager.swift  # NSStatusItem + 角标渲染
│   ├── Models.swift          # AppItem, AppCategory, SavedState
│   └── LocalizationManager.swift  # 中英双语文案管理
├── Resources/
│   ├── Info.plist
│   └── AppIcon.icns
├── build.sh                  # swiftc 编译脚本，无需 Xcode
└── generate_icon.sh
```

## 快速定位

| 任务 | 文件 | 入口 |
|------|------|------|
| 电源切换时自动停止/恢复 | `BatKillApp.swift` | `queuePowerAction()` / `processNextPowerAction()` |
| 电源状态检测 | `BatteryMonitor.swift` | `checkPowerState()` (IOKit) |
| 杀掉应用 | `ProcessKiller.swift` | `killSelected()` → `terminate()` |
| 恢复被杀的软件 | `ProcessKiller.swift` | `restoreKilledApps()` → `restoreSingleApp()` |
| 发现已安装应用 | `AppLister.swift` | `buildAppList()` |
| 被杀应用的持久化列表 | `ProcessKiller.swift` | `killedRestorePaths` (UserDefaults key) |
| 用户勾选持久化 | `AppLister.swift` | `selectedPaths` (UserDefaults key) |
| 角标数字 | `BatKillApp.swift` | `refreshBadge()` |
| 国际化文案 | `LocalizationManager.swift` | `translate(_:_:)` / `loc(_:_:)` |

## 约定

- **无 Xcode 工程** — 通过 `build.sh` 调用 `swiftc` 编译
- **Parse-as-library** — 主入口为 `@main struct BatKillApp` (SwiftUI App)
- **LSUIElement = true** — 仅菜单栏，无 Dock 图标（设置窗口通过代码打开）
- **文件日志** → `/tmp/batkill.log`，带时间戳
- **零外部依赖** — 仅使用 Apple SDK
- **国际化** — 英文 + 简体中文，所有面向用户的文案使用 `lm.translate(en, zh)`
- **UserDefaults key**: `killedRestorePaths`, `selectedAppPaths`, `knownSystemPaths`, `autoKillEnabled`, `appLanguage`
- **电源动作队列** — 通过合并中间状态实现去抖 + 操作完成后 5 秒延时，禁止内联调用

## 反模式（禁止）

- **禁止** 绕过电源队列直接调用 `killSelected()`/`restoreKilledApps()` — 必须通过 `AppDelegate` 的 `queuePowerAction()`
- **禁止** 屏蔽 `isOnBattery` 变化 — 快速插拔已由队列的合并机制处理（`pendingPowerAction` 覆盖写入）
- **禁止** 无充分理由引入外部依赖 — 零依赖是目标
- **禁止** 移除 `trackForRestore` 路径 — UI 手动停止也应追踪（除非明确不需要）
- **禁止** 在电源过渡逻辑中使用 `as any`/`@ts-ignore` 等 — Swift 类型安全是语言特性

## 命令

```bash
# 编译
bash build.sh

# 运行（编译后）
open .build/BatKill.app

# 查看日志
tail -f /tmp/batkill.log
```

## 注意事项

- `pendingPowerAction: Bool?` 编码三种状态：`nil` = 无等待，`true` = 电池动作（停止），`false` = 交流电动作（恢复）
- `isKilling`/`isRestoring` 仅用于 UI 指示，队列内部使用 `powerActionInProgress` 做互斥
- `checkPowerState()` 同时通过 IOKit 回调和 5 秒轮询定时器触发（双重保障）
- 恢复列表 `killedRestorePaths` 只记录**成功终止**的软件
