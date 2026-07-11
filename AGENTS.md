# BatKill — 项目知识库

**更新日期:** 2026-07-11
**版本:** v0.0.15
**技术栈:** Swift 5 / SwiftUI / AppKit / IOKit / Combine / AuthorizationServices
**目标系统:** macOS 14.0+ (arm64 + x86_64)
**Bundle ID:** com.batkill.app

## 概述

菜单栏常驻工具，电池供电时自动终止用户勾选的软件，接入交流电时自动恢复。附带实时硬件温度监控、风扇控制与自动更新功能。

## 功能

- **电池时自动停止** — Mac 切换到电池供电后，自动终止用户勾选的软件（30秒延迟，智能去抖）
- **接入交流电自动恢复** — 插上电源后，自动重新启动被终止的软件
- **智能电源队列** — 快速插拔电源时合并中间状态，仅对最终状态执行操作；操作完成后冷却间隔
- **单实例运行** — 重复启动会自动聚焦已有实例
- **零依赖** — 纯 `swiftc` 编译，仅使用 Apple SDK
- **双语支持** — 英文 / 简体中文
- **CPU 温度监控** — 实时显示各核心温度（通过 SMC 读取，P-Core / E-Core 动态命名）
- **风扇控制** — 查看风扇转速，手动调节转速或切换自动/手动模式（0-1200 RPM 步进 100，1200+ 步进 1）
- **风扇预设** — 保存/加载/删除风扇配置方案，内置「自动模式」预设，UserDefaults 持久化
- **温度阈值保护** — 可设置 CPU 温度阈值（60-120°C），超过后自动将风扇交还系统控制
- **过温守护** — 超过阈值时锁定手动模式，已授权时自动恢复风扇自动模式
- **动态 CPU 命名** — 通过 sysctl 获取核心拓扑，自动分配 P-Core/E-Core 标签
- **系统信息** — 显示 CPU 型号、内存容量、磁盘容量
- **温度角标** — 设置图标上叠加实时 CPU 温度值
- **已选/待恢复列表** — 独立弹窗管理已选程序和待恢复程序
- **状态栏通知** — 电源切换时在菜单栏下方显示简短通知
- **自动更新** — 从 GitHub Release 检测并下载更新

## 目录结构

```
BatKill/
├── Sources/
│   ├── App/                        # 应用入口与委托
│   │   ├── BatKillApp.swift           # @main SwiftUI 入口
│   │   ├── AppDelegate.swift          # 应用委托、电源队列、窗口管理
│   │   └── CLIFanWriter.swift         # CLI 风扇写入（管理员提权通道）
│   ├── Core/                       # 基础工具
│   │   ├── Logger.swift               # 文件日志 (/tmp/batkill.log)
│   │   └── Extensions.swift           # Binding.onChange、Notification.Name 扩展
│   ├── Models/                     # 数据模型
│   │   ├── AppItem.swift              # AppItem、AppCategory
│   │   ├── FanPreset.swift            # FanPreset、FanPresetStore
│   │   ├── HardwareModels.swift       # 温度传感器、风扇信息、SMC 数据结构
│   │   └── ThresholdStore.swift       # 温度阈值持久化存储
│   ├── Services/                   # 业务逻辑层
│   │   ├── BatteryMonitor.swift       # IOKit 电源状态监听
│   │   ├── ProcessKiller.swift        # 终止/恢复应用、启动代理、后台服务
│   │   ├── AppLister.swift            # 应用发现（.app、LaunchAgents、brew services）
│   │   ├── HardwareMonitor.swift      # SMC 连接与读写核心
│   │   ├── TemperatureReading.swift   # 温度传感器键映射与解码
│   │   ├── FanController.swift        # 风扇读写与管理员授权
│   │   ├── LocalizationManager.swift  # 中英双语翻译管理
│   │   └── Updater.swift              # GitHub Release 版本检测与更新
│   ├── Views/                      # SwiftUI 视图
│   │   ├── SettingsView.swift         # 主设置窗口
│   │   ├── AppRowView.swift           # 应用列表行组件
│   │   ├── SelectedAppsSheet.swift    # 已选应用列表弹窗
│   │   ├── PendingRestoreSheet.swift  # 待恢复应用列表弹窗
│   │   ├── PopoverView.swift          # 菜单栏弹窗
│   │   └── TemperatureView.swift      # 温度监控窗口
│   └── UI/                         # 系统级 UI
│       └── MenuBarManager.swift       # NSStatusItem、角标渲染、右键菜单、通知面板
├── Resources/
│   ├── Info.plist
│   └── AppIcon.icns
├── Releases/
│   ├── arm64/BatKill-arm.app        # arm64 打包
│   └── x86_64/BatKill-x86.app      # x86_64 打包
├── build.sh                         # swiftc 编译脚本，无需 Xcode
└── generate_icon.sh
```

## 快速定位

| 任务 | 文件 | 入口 |
|------|------|------|
| 电源切换时自动停止/恢复 | `App/AppDelegate.swift` | `queuePowerAction()` / `processNextPowerAction()` |
| 电源状态检测 | `Services/BatteryMonitor.swift` | `checkPowerState()` (IOKit) |
| 杀掉应用 | `Services/ProcessKiller.swift` | `killSelected()` → `terminate()` |
| 恢复被杀的软件 | `Services/ProcessKiller.swift` | `restoreKilledApps()` → `restoreSingleApp()` |
| 发现已安装应用 | `Services/AppLister.swift` | `buildAppList()` |
| SMC 温度读取 | `Services/TemperatureReading.swift` | `readTemperatures()` |
| SMC 风扇读取 | `Services/FanController.swift` | `readFans()` |
| 风扇写入 (需管理员) | `Services/FanController.swift` | `setFanSpeedWithAdmin()` |
| 管理员授权 | `Services/FanController.swift` | `requestAdminAuth()` |
| SMC 连接 | `Services/HardwareMonitor.swift` | `open()` / `readKeyData()` / `writeBytes()` |
| 温度窗口 | `Views/TemperatureView.swift` | `TemperatureView` (SwiftUI) |
| 风扇预设管理 | `Models/FanPreset.swift` | `FanPresetStore` (UserDefaults) |
| 角标数字 | `App/AppDelegate.swift` | `refreshBadge()` |
| 国际化文案 | `Services/LocalizationManager.swift` | `translate(_:_:)` / `loc(_:_:)` |
| 被杀应用的持久化列表 | `Services/ProcessKiller.swift` | `killedRestorePaths` (UserDefaults) |
| 用户勾选持久化 | `Services/AppLister.swift` | `selectedPaths` (UserDefaults) |

## 约定

- **无 Xcode 工程** — 通过 `build.sh` 调用 `swiftc` 编译
- **Parse-as-library** — 主入口为 `@main struct BatKillApp` (SwiftUI App)
- **LSUIElement = true** — 仅菜单栏，无 Dock 图标（设置窗口通过代码打开）
- **文件日志** → `/tmp/batkill.log`，带时间戳
- **零外部依赖** — 仅使用 Apple SDK
- **国际化** — 英文 + 简体中文，所有面向用户的文案使用 `lm.translate(en, zh)`
- **UserDefaults key**: `killedRestorePaths`, `selectedAppPaths`, `knownSystemPaths`, `autoKillEnabled`, `appLanguage`, `fanPresets`, `activeFanPresetId`, `cpuTemperatureBadge`, `temperatureThreshold`
- **电源动作队列** — 通过合并中间状态实现去抖 + 操作完成后冷却延时（30秒延迟），禁止内联调用
- **管理员授权** — 通过 `AuthorizationServices` 实现一次性会话授权（`AuthorizationCreate` + `AuthorizationCopyRights`）
- **SMC 写入** — 风扇转速 `fpe2` 类型需 ×4 写入；`flt` 类型使用 Float32 编码

## 反模式（禁止）

- **禁止** 绕过电源队列直接调用 `killSelected()`/`restoreKilledApps()` — 必须通过 `AppDelegate` 的 `queuePowerAction()`
- **禁止** 屏蔽 `isOnBattery` 变化 — 快速插拔已由队列的合并机制处理（`pendingPowerAction` 覆盖写入）
- **禁止** 无充分理由引入外部依赖 — 零依赖是目标
- **禁止** 移除 `trackForRestore` 路径 — UI 手动停止也应追踪（除非明确不需要）
- **禁止** 在电源过渡逻辑中使用 `as any`/`@ts-ignore` 等 — Swift 类型安全是语言特性
- **禁止** 绕过管理员授权直接调用 SMC 写入 — 必须通过 `setFanSpeedWithAdmin()` / `setFanModeWithAdmin()`
- **禁止** 在 `showSettingsWindow()` 中遗漏 `@EnvironmentObject` — ContentView 需要全部环境对象

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
  -parse-as-library -o .build-x86/BatKill \
  Sources/App/*.swift Sources/Core/*.swift Sources/Models/*.swift \
  Sources/Services/*.swift Sources/Views/*.swift Sources/UI/*.swift \
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
- `checkPowerState()` 同时通过 IOKit 回调和轮询定时器触发（双重保障）
- 恢复列表 `killedRestorePaths` 只记录**成功终止**的软件
- 风扇预设存储在 UserDefaults 中（key: `fanPresets`），支持保存/加载/删除/激活
- 管理员授权通过 `dlsym` 动态加载 `AuthorizationExecuteWithPrivileges`（已废弃 API，不在 Swift 头文件中）
- 交叉编译命令需按子目录逐个 glob 源文件（不再使用 `Sources/*.swift` 通配符）
