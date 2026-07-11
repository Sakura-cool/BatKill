//  HardwareModels.swift
//  BatKill
//
//  Data structures for low-level SMC (System Management Controller) communication
//  and high-level hardware monitoring models (temperature sensors, fan info).
//
//  The SMC structs mirror the C structs used by IOKit's SMC user-space client.
//  The temperature and fan models are used by HardwareMonitor to present hardware
//  data to the SwiftUI views.
//
//  Extracted from: HardwareMonitor.swift

import Foundation

// MARK: - SMC Data Structures

/// Metadata returned by the SMC for a given key.
///
/// Contains the data type (as a `FourCharCode`), the size of the data payload,
/// and attribute flags used by the SMC kernel driver.
struct SMCKeyInfoData {
    /// Size of the data payload in bytes (max 32 for SMC reads/writes).
    var dataSize: UInt32 = 0

    /// Four-character code identifying the data type (e.g., `flt `, `fpe2`, `sp78`).
    var dataType: FourCharCode = 0

    /// Attribute flags for the SMC key (read/write permissions, data format hints).
    var dataAttributes: UInt8 = 0
}

/// Parameter block used for all SMC read/write operations via IOKit.
///
/// This struct is passed to `IOConnectCallStructMethod` for SMC communication.
/// The kernel interprets `data8` as the command code and populates `result`/`status`
/// on return. The 32-byte `bytes` field carries the actual data payload.
///
/// Based on the undocumented SMC client interface used by Apple's `powermetrics`
/// and third-party tools like `iStat` and `Macs Fan Control`.
struct SMCParamStruct {
    /// Four-character key identifying the SMC property (e.g., "TCPU", "F0Ac", "FNum").
    var key: FourCharCode = 0

    /// SMC version info (unused in practice; zeroed out).
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)

    /// Padding/limit data (unused in read/write operations).
    var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)

    /// Key metadata (data type, size, attributes) populated by `kSMCGetKeyInfo` command.
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()

    /// Alignment padding (unused).
    var padding: UInt16 = 0

    /// Result code returned by the SMC after a command (0 = success).
    var result: UInt8 = 0

    /// Status code returned by the SMC after a command.
    var status: UInt8 = 0

    /// Command code:
    ///   - `5` (`kSMCReadKey`): Read the value of a key.
    ///   - `6` (`kSMCWriteKey`): Write a value to a key.
    ///   - `9` (`kSMCGetKeyInfo`): Retrieve metadata (type, size) for a key.
    var data8: UInt8 = 0

    /// Data type index (used for indexed type access; typically 0).
    var dataTypeIndex: UInt32 = 0

    /// 32-byte data payload buffer.
    /// For reads: filled by the kernel with the key's value.
    /// For writes: contains the value to set.
    /// For get-key-info: ignored (metadata comes via `keyInfo`).
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// MARK: - SMC Command Constants

let kSMCReadKey: UInt8 = 5

let kSMCWriteKey: UInt8 = 6

let kSMCGetKeyInfo: UInt8 = 9

// MARK: - Temperature Sensor

/// A single temperature reading from an SMC sensor.
///
/// Each sensor has a 4-character SMC key (e.g., "TCPU", "Tp01"), a human-readable name,
/// the current temperature in degrees Celsius, and a category for UI grouping.
struct TemperatureSensor: Identifiable {
    /// Unique identifier for this sensor (auto-generated; not the SMC key).
    let id = UUID()

    /// 4-character SMC key used to read this sensor's value (e.g., "TCPU", "Tp01", "TG0D").
    let key: String

    /// Human-readable name for display in the temperature window (e.g., "CPU Core 0", "GPU Die").
    let name: String

    /// Current temperature reading in degrees Celsius.
    let temperature: Double

    /// The hardware category this sensor belongs to (CPU, GPU, Memory, etc.).
    let category: TemperatureCategory
}

// MARK: - Temperature Category

/// High-level hardware category for grouping temperature sensors in the UI.
///
/// Each case maps to an SF Symbol icon and bilingual localized name (English + Chinese).
/// Sensors are automatically classified during the SMC scan based on their key prefix.
enum TemperatureCategory: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case battery = "Battery"
    case storage = "Storage"
    case ambient = "Ambient"
    case other = "Other"

    /// Stable identifier matching the raw value.
    var id: String { rawValue }

    /// SF Symbol name used to represent this category in the temperature UI.
    var systemImage: String {
        switch self {
        case .cpu:     return "cpu"
        case .gpu:     return "display"
        case .memory:  return "memorychip"
        case .battery: return "battery.100"
        case .storage: return "internaldrive"
        case .ambient: return "thermometer.medium"
        case .other:   return "gearshape"
        }
    }

    /// Bilingual localized name tuple for display in the UI.
    /// `.en` = English, `.zh` = Simplified Chinese.
    var localizedName: (en: String, zh: String) {
        switch self {
        case .cpu:     return ("CPU", "处理器")
        case .gpu:     return ("GPU", "显卡")
        case .memory:  return ("Memory", "内存")
        case .battery: return ("Battery", "电池")
        case .storage: return ("Storage", "存储")
        case .ambient: return ("Ambient", "环境")
        case .other:   return ("Other", "其他")
        }
    }
}

// MARK: - Temperature Group

/// A grouped collection of temperature sensors belonging to the same hardware category.
///
/// Used by the temperature UI to display collapsible sections (e.g., "CPU" with all core
/// sensors, "GPU" with die/package/memory sensors). Provides a computed `average` for
/// the group's temperature.
struct TemperatureGroup: Identifiable {
    /// The hardware category that all sensors in this group belong to.
    let category: TemperatureCategory

    /// All individual sensors within this category.
    let sensors: [TemperatureSensor]

    /// Group identifier matches the category, enabling stable list identity in SwiftUI.
    var id: TemperatureCategory { category }

    /// Arithmetic mean of all sensor temperatures in this group.
    /// Returns `0` if the group has no sensors.
    var average: Double {
        guard !sensors.isEmpty else { return 0 }
        return sensors.map(\.temperature).reduce(0, +) / Double(sensors.count)
    }
}

// MARK: - Fan Info

/// Describes a single physical fan detected via the SMC.
///
/// Contains the fan's index, name, speed range (min/max), current speed,
/// and whether it is in automatic (system-managed) or manual mode.
struct FanInfo: Identifiable {
    /// Unique identifier for this fan (auto-generated; not the fan index).
    let id = UUID()

    /// Zero-based index of this fan (used in SMC key construction, e.g., "F0Ac" for fan 0).
    let index: Int

    /// Human-readable name read from the SMC (e.g., "Left", "Right").
    /// Falls back to "Fan N" if the name cannot be read.
    let name: String

    /// Minimum supported fan speed in RPM.
    let minSpeed: Double

    /// Maximum supported fan speed in RPM.
    let maxSpeed: Double

    /// Current fan speed in RPM.
    let currentSpeed: Double

    /// Whether the fan is in automatic mode (`true`) or manual mode (`false`).
    /// In auto mode, the system firmware controls the fan speed based on thermal conditions.
    let isAutoMode: Bool
}
