# BatKill

macOS 菜单栏工具，在电池供电时自动停止指定应用，接入交流电时自动恢复。

## 功能

- **电池时自动停止** — Mac 切换到电池供电后，自动终止用户勾选的软件
- **接入交流电自动恢复** — 插上电源后，自动重新启动被终止的软件
- **智能队列** — 快速插拔电源时合并中间状态，仅对最终状态执行操作；每次操作完成后有 5 秒冷却间隔
- **单实例运行** — 重复启动会自动聚焦已有实例
- **零依赖** — 纯 `swiftc` 编译，仅使用 Apple SDK
- **双语支持** — 英文 / 简体中文

## 系统要求

- macOS 14.0+ (Sonoma)

## 编译

```bash
git clone <repo> && cd BatKill
bash build.sh
open .build/BatKill.app
```

## 使用

1. 启动 BatKill — 菜单栏出现电池图标
2. 右键点击图标 → "显示窗口" 打开设置
3. 勾选需要在电池时自动停止的软件
4. 打开 "使用电池时自动停止" 开关

电池状态下：勾选的运行中软件会被终止。接入交流电后：被终止的软件会自动恢复。

## 调试日志

```bash
tail -f /tmp/batkill.log
```

## 构建说明

- 无需 Xcode — 通过 `build.sh` 直接调用 `swiftc` 编译
- Parse-as-library 模式，`@main` SwiftUI App 入口
- `LSUIElement = true`（无 Dock 图标，仅菜单栏运行）

## 许可

MIT
