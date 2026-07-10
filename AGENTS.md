# BatKill — 项目知识库

**更新日期:** 2026-07-10
**版本:** v0.0.12
**技术栈:** Swift 5 / SwiftUI / AppKit / IOKit / Combine / AuthorizationServices
**目标系统:** macOS 14.0+ (arm64 + x86_64)
**Bundle ID:** com.batkill.app

## 概述

菜单栏常驻工具，电池供电时自动终止用户勾选的软件，接入交流电时自动恢复。附带实时温度监控和风扇控制功能。

## 功能

- **电池时自动停止** — Mac 切换到电池供电后，自动终止用户勾选的软件
- **接入交流电自动恢复** — 插上电源后，自动重新启动被终止的软件
- **智能队列** — 快速插拔电源时合并中间状态，仅对最终状态执行操作；每次操作完成后有 5 秒冷却间隔
- **单实例运行** — 重复启动会自动聚焦已有实例
- **零依赖** — 纯 `swiftc` 编译，仅使用 Apple SDK
- **双语支持** — 英文 / 简体中文
- **温度监控** — 实时显示 CPU 各核心温度（通过 SMC 读取）
- **风扇控制** — 查看风扇转速，手动调节转速或切换自动/手动模式
- **风扇预设** — 保存/加载/删除风扇配置方案，支持 UserDefaults 持久化
- **动态 CPU 命名** — 通过 sysctl 获取核心拓扑，自动分配 P-Core/E-Core 标签

## 目录结构

```
BatKill/
├── Sources/
│   ├── BatKillApp.swift          # @main 入口, AppDelegate, 电源动作队列
│   ├── BatteryMonitor.swift      # IOKit 电源状态监听器
│   ├── ProcessKiller.swift       # 停止/恢复逻辑、持久化、通知
│   ├── AppLister.swift           # 发现应用、启动代理、后台服务
│   ├── ContentView.swift         # 设置窗口 (SwiftUI)
│   ├── PopoverView.swift         # 菜单栏弹窗
│   ├── MenuBarManager.swift      # NSStatusItem + 角标渲染 + 右键菜单
│   ├── Models.swift              # AppItem, AppCategory, FanPreset, FanPresetStore
│   ├── HardwareMonitor.swift     # SMC 温度/风扇读写, 管理员授权
│   ├── TemperatureView.swift     # 温度窗口: 折叠分组 + 风扇控制 + 预设
│   └── LocalizationManager.swift # 中英双语文案管理
├── Resources/
│   ├── Info.plist
│   └── AppIcon.icns
├── Releases/
│   ├── arm64/BatKill-arm.app    # arm64 打包
│   └── x86_64/BatKill-x86.app  # x86_64 打包
├── build.sh                     # swiftc 编译脚本，无需 Xcode
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
| SMC 温度读取 | `HardwareMonitor.swift` | `readTemperature()` / `appleSiliconKeys` |
| SMC 风扇读取 | `HardwareMonitor.swift` | `readFanSpeed()` / `readFanTarget()` / `readFanMode()` |
| 风扇写入 (需管理员) | `HardwareMonitor.swift` | `setFanSpeedWithAdmin()` / `setFanModeWithAdmin()` |
| 管理员授权 | `HardwareMonitor.swift` | `requestAdminAuth()` / `isAdminAuthorized` |
| 动态 CPU 命名 | `HardwareMonitor.swift` | `buildCPUSensorMap()` via sysctl |
| 温度窗口 | `TemperatureView.swift` | `TemperatureView` (SwiftUI) |
| 风扇预设管理 | `Models.swift` | `FanPresetStore` (UserDefaults) |
| 角标数字 | `BatKillApp.swift` | `refreshBadge()` |
| 国际化文案 | `LocalizationManager.swift` | `translate(_:_:)` / `loc(_:_:)` |
| 被杀应用的持久化列表 | `ProcessKiller.swift` | `killedRestorePaths` (UserDefaults) |
| 用户勾选持久化 | `AppLister.swift` | `selectedPaths` (UserDefaults) |

## 约定

- **无 Xcode 工程** — 通过 `build.sh` 调用 `swiftc` 编译
- **Parse-as-library** — 主入口为 `@main struct BatKillApp` (SwiftUI App)
- **LSUIElement = true** — 仅菜单栏，无 Dock 图标（设置窗口通过代码打开）
- **文件日志** → `/tmp/batkill.log`，带时间戳
- **零外部依赖** — 仅使用 Apple SDK
- **国际化** — 英文 + 简体中文，所有面向用户的文案使用 `lm.translate(en, zh)`
- **UserDefaults key**: `killedRestorePaths`, `selectedAppPaths`, `knownSystemPaths`, `autoKillEnabled`, `appLanguage`, `fanPresets`, `activeFanPresetId`
- **电源动作队列** — 通过合并中间状态实现去抖 + 操作完成后 5 秒延时，禁止内联调用
- **管理员授权** — 通过 `AuthorizationServices` 实现一次性会话授权（`AuthorizationCreate` + `AuthorizationCopyRights`）
- **SMC 写入** — 风扇转速 `fpe2` 类型需 ×4 写入；`flt` 类型使用 Float32 编码

## 反模式（禁止）

- **禁止** 绕过电源队列直接调用 `killSelected()`/`restoreKilledApps()` — 必须通过 `AppDelegate` 的 `queuePowerAction()`
- **禁止** 屏蔽 `isOnBattery` 变化 — 快速插拔已由队列的合并机制处理（`pendingPowerAction` 覆盖写入）
- **禁止** 无充分理由引入外部依赖 — 零依赖是目标
- **禁止** 移除 `trackForRestore` 路径 — UI 手动停止也应追踪（除非明确不需要）
- **禁止** 在电源过渡逻辑中使用 `as any`/`@ts-ignore` 等 — Swift 类型安全是语言特性
- **禁止** 绕过管理员授权直接调用 SMC 写入 — 必须通过 `setFanSpeedWithAdmin()` / `setFanModeWithAdmin()`
- **禁止** 在 `showSettingsWindow()` 中遗漏 `@EnvironmentObject` — ContentView 需要全部 7 个环境对象

## SMC 传感器映射 (Apple Silicon)

有效 Tp 键通过动态扫描 Tp01-Tp0D 确定（跳过已知缺失的 Tp03/Tp07），按顺序分配：
- P-Core 1~N → 前 N 个有效键
- E-Core 1~M → 后 M 个有效键
- CPU P-Core Aggregate → 所有 P-Core 传感器平均值
- E-Core Aggregate → 独立键 (Tp0b)

## 命令

```bash
# 编译 (arm64)
bash build.sh

# 交叉编译 (x86_64)
SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"
swiftc -sdk "$SDK_PATH" -target x86_64-apple-macosx14.0 \
  -parse-as-library -o .build-x86/BatKill Sources/*.swift \
  -framework SwiftUI -framework AppKit -framework IOKit \
  -framework UserNotifications -framework ServiceManagement -framework Combine

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
- 风扇预设存储在 UserDefaults 中（key: `fanPresets`），支持保存/加载/删除/激活
- 管理员授权通过 `dlsym` 动态加载 `AuthorizationExecuteWithPrivileges`（已废弃 API，不在 Swift 头文件中）
