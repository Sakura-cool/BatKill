# BatKill

macOS menu bar tool — Automatically terminates specified apps on battery power, restores them when plugged in. Includes real-time hardware temperature monitoring and fan control.

## Features

- **Auto-terminate on battery** — Automatically kills selected apps when Mac switches to battery power (30-second delay with smart debouncing)
- **Auto-restore on AC power** — Automatically restarts terminated apps when power is connected
- **Smart power queue** — Debounces rapid power plug/unplug events, only acts on final state
- **Single instance** — Duplicate launches automatically focus the existing instance
- **Zero dependencies** — Pure `swiftc` compilation, only uses Apple SDK, no Xcode required
- **Bilingual support** — English / Simplified Chinese
- **CPU temperature monitoring** — Real-time display of per-core temperatures (P-Core / E-Core dynamic naming)
- **Fan control** — View fan speeds, manual/auto mode switching (0-1200 RPM step 100, 1200+ step 1)
- **Fan presets** — Save/load/delete fan configuration presets, built-in "Auto" preset
- **Temperature threshold** — Set CPU temperature threshold (60-120°C), automatically returns fan to system control when exceeded
- **Overheat protection** — Locks manual mode when threshold exceeded, automatically restores fan to auto mode
- **System info** — Displays CPU model, memory capacity, disk capacity
- **Temperature badge** — Overlay real-time CPU temperature on the menu bar icon
- **Selected/restore lists** — Independent windows to manage selected and pending-restore apps
- **Status bar notifications** — Brief notifications below menu bar on power state changes
- **Auto updates** — Detects and downloads updates from GitHub Releases

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon (arm64) or Intel (x86_64)

## Build & Run

```bash
git clone https://github.com/Sakura-cool/BatKill.git && cd BatKill
bash build.sh
open .build/BatKill.app
```

## Usage

1. Launch BatKill — Battery icon appears in menu bar
2. **Left-click icon** → Popover shows battery status and quick actions
3. **Click temperature icon** → Opens hardware monitoring window (CPU temperature, fan control, preset management)
4. **Click "Settings"** → Select apps to auto-terminate on battery
5. **Right-click icon** → "Show Window" opens settings / "Quit" exits app

On battery: Selected running apps are terminated. On AC power: Terminated apps are automatically restored.

## Debug Logs

```bash
tail -f /tmp/batkill.log
```

## Project Structure

```
Sources/
├── App/                        # App entry point and delegate
│   ├── BatKillApp.swift           # @main SwiftUI entry point
│   ├── AppDelegate.swift          # App delegate, power queue, window management
│   └── CLIFanWriter.swift         # CLI fan write (admin privilege channel)
├── Core/                       # Core utilities
│   ├── Logger.swift               # File logging (/tmp/batkill.log)
│   └── Extensions.swift           # Binding.onChange, Notification.Name extensions
├── Models/                     # Data models
│   ├── AppItem.swift              # AppItem, AppCategory
│   ├── FanPreset.swift            # FanPreset, FanPresetStore
│   ├── HardwareModels.swift       # Temperature sensors, fan info, SMC data structures
│   └── ThresholdStore.swift       # Temperature threshold persistence
├── Services/                   # Business logic layer
│   ├── BatteryMonitor.swift       # IOKit power state monitoring
│   ├── ProcessKiller.swift        # Kill/restore apps, launch agents, background services
│   ├── AppLister.swift            # App discovery (.app, LaunchAgents, brew services)
│   ├── HardwareMonitor.swift      # SMC connection and read/write core
│   ├── TemperatureReading.swift   # Temperature sensor key mapping and decoding
│   ├── FanController.swift        # Fan read/write and admin authorization
│   ├── LocalizationManager.swift  # Bilingual translation management
│   └── Updater.swift              # GitHub Release version checking and updates
├── Views/                      # SwiftUI views
│   ├── SettingsView.swift         # Main settings window
│   ├── AppRowView.swift           # App list row component
│   ├── SelectedAppsSheet.swift    # Selected apps list sheet
│   ├── PendingRestoreSheet.swift  # Pending restore apps list sheet
│   ├── PopoverView.swift          # Menu bar popover
│   └── TemperatureView.swift      # Temperature monitoring window
└── UI/                         # System-level UI
    └── MenuBarManager.swift       # NSStatusItem, badge rendering, context menu, notifications
```

## License

MIT
