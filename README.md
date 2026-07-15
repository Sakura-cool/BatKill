# BatKill

macOS 菜单栏工具 — 电池供电时自动终止指定软件，接入交流电时自动恢复。附带实时硬件温度监控与风扇控制。

## 功能特性

- **电池自动停止** — Mac 切换到电池供电后，自动终止用户勾选的软件（30秒延迟，智能去抖）
- **接入交流电自动恢复** — 插上电源后，自动重新启动被终止的软件
- **智能电源队列** — 快速插拔电源时合并中间状态，仅对最终状态执行操作
- **单实例运行** — 重复启动会自动聚焦已有实例
- **零依赖** — 纯 `swiftc` 编译，仅使用 Apple SDK，无需 Xcode
- **双语支持** — 英文 / 简体中文
- **CPU 温度监控** — 实时显示各核心温度（P-Core / E-Core 动态命名）
- **风扇控制** — 查看转速，手动/自动模式切换（0-1200 RPM 步进 100，1200+ 步进 1）
- **风扇预设** — 保存/加载/删除风扇配置方案，内置「自动模式」预设
- **温度阈值保护** — 可设置 CPU 温度阈值（60-120°C），超过后自动将风扇交还系统控制
- **过温守护** — 超过阈值时锁定手动模式，自动恢复风扇自动模式
- **系统信息** — 显示 CPU 型号、内存容量、磁盘容量
- **温度角标** — 设置图标上叠加实时 CPU 温度值
- **已选/待恢复列表** — 独立弹窗管理已选程序和待恢复程序
- **状态栏通知** — 电源切换时在菜单栏下方显示简短通知
- **自动更新** — 从 GitHub Release 检测并下载更新

## 系统要求

- macOS 14.0+ (Sonoma)
- Apple Silicon (arm64) 或 Intel (x86_64)

## 编译与运行

```bash
git clone https://github.com/Sakura-cool/BatKill.git && cd BatKill
bash build.sh                    # 编译（输出 .build/arm64/BatKill-arm64.app）
open .build/arm64/BatKill-arm64.app
```

**发版打包（DMG）：**

```bash
bash build.sh --dmg              # 编译 + DMG 打包
# 输出 .package/arm64/BatKill-arm64.dmg
```

## 使用说明

1. 启动 BatKill — 菜单栏出现电池图标
2. **左键点击图标** → 弹窗显示电池状态和快捷操作
3. **点击温度图标** → 打开硬件监控窗口（CPU 温度、风扇控制、预设管理）
4. **点击「设置」** → 勾选需要在电池时自动停止的软件
5. **右键点击图标** → "显示窗口" 打开设置 / "退出" 关闭程序

电池状态下：勾选的运行中软件会被终止。接入交流电后：被终止的软件会自动恢复。

## 调试日志

```bash
tail -f /tmp/batkill.log
```

## 项目结构

```
Sources/
├── App/                        # 应用入口与委托
│   ├── BatKillApp.swift           # @main SwiftUI 入口
│   ├── AppDelegate.swift          # 应用委托、电源队列、窗口管理
│   └── CLIFanWriter.swift         # CLI 风扇写入（管理员提权通道）
├── Core/                       # 基础工具
│   ├── Logger.swift               # 文件日志 (/tmp/batkill.log)
│   └── Extensions.swift           # Binding.onChange、Notification.Name 扩展
├── Models/                     # 数据模型
│   ├── AppItem.swift              # AppItem、AppCategory
│   ├── FanPreset.swift            # FanPreset、FanPresetStore
│   ├── HardwareModels.swift       # 温度传感器、风扇信息、SMC 数据结构
│   └── ThresholdStore.swift       # 温度阈值持久化存储
├── Services/                   # 业务逻辑层
│   ├── BatteryMonitor.swift       # IOKit 电源状态监听
│   ├── ProcessKiller.swift        # 终止/恢复应用、启动代理、后台服务
│   ├── AppLister.swift            # 应用发现（.app、LaunchAgents、brew services）
│   ├── HardwareMonitor.swift      # SMC 连接与读写核心
│   ├── TemperatureReading.swift   # 温度传感器键映射与解码
│   ├── FanController.swift        # 风扇读写与管理员授权
│   ├── LocalizationManager.swift  # 中英双语翻译管理
│   └── Updater.swift              # GitHub Release 版本检测与更新
├── Views/                      # SwiftUI 视图
│   ├── SettingsView.swift         # 主设置窗口
│   ├── AppRowView.swift           # 应用列表行组件
│   ├── SelectedAppsSheet.swift    # 已选应用列表弹窗
│   ├── PendingRestoreSheet.swift  # 待恢复应用列表弹窗
│   ├── PopoverView.swift          # 菜单栏弹窗
│   └── TemperatureView.swift      # 温度监控窗口
└── UI/                         # 系统级 UI
    └── MenuBarManager.swift       # NSStatusItem、角标渲染、右键菜单、通知面板
```

## 许可

MIT
