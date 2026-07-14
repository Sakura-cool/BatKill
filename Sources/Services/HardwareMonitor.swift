//  HardwareMonitor.swift
//  BatKill
//
//  Core SMC (System Management Controller) connection, read/write primitives,
//  and hardware monitoring orchestration. Provides the foundation for
//  temperature reading (see TemperatureReading.swift) and fan control
//  (see FanController.swift).
//
//  TemperatureSensor, TemperatureCategory, TemperatureGroup, and FanInfo
//  model types are defined here and shared across all hardware-related code.

import Foundation
import IOKit
import Security

// Model types (TemperatureSensor, TemperatureCategory, TemperatureGroup, FanInfo)
// are defined in Models/HardwareModels.swift and shared across all files.
// SMC data structures (SMCKeyInfoData, SMCParamStruct) are also in Models/HardwareModels.swift.

// MARK: - HardwareMonitor

/// Core hardware monitoring class that manages the SMC connection and
/// provides temperature/fan data to the rest of the application.
///
/// Temperature sensor reading logic is in `TemperatureReading.swift`.
/// Fan control and admin authorization are in `FanController.swift`.
///
/// Usage: `HardwareMonitor.shared` (singleton).
final class HardwareMonitor: ObservableObject {
    // MARK: Published Properties

    /// All detected temperature sensor readings, updated on each refresh.
    @Published var temperatures: [TemperatureSensor] = []

    /// All detected fan information, updated on each refresh.
    @Published var fans: [FanInfo] = []

    /// Whether the SMC connection was successfully established.
    @Published var isAvailable = false

    /// Whether the last fan write operation succeeded (for UI feedback).
    @Published var lastFanWriteOK = false

    /// Whether the CPU has exceeded the thermal threshold.
    @Published var thermalThrottled = false

    /// Highest individual P-Core temperature (excluding aggregates).
    @Published var maxCPUTemp: Double = 0

    /// Whether admin authorization has been granted for SMC writes.
    @Published var isAdminAuthorized = false

    // MARK: Callbacks

    /// Called once when `thermalThrottled` transitions from false to true.
    var onThermalThrottle: (() -> Void)?

    // MARK: SMC Type Constants

    /// `flt` — 32-bit float type (used by some temperature and fan keys).
    static let fltType  = FourCharCode(0x666C7420)

    /// `fds` — signed 16-bit fixed-point with 2 fractional bits (scale /4).
    static let fdsType  = FourCharCode(0x7B666473)

    /// `fpe2` — unsigned 16-bit fixed-point with 2 integer + 14 fractional bits
    /// (scale /4 for fan speeds, /64 for temperatures).
    static let fpe2Type = FourCharCode(0x66706532)

    /// `sp78` — signed 16-bit fixed-point with 7 integer + 8 fractional bits
    /// (scale /256, common for Apple Silicon temperature keys).
    static let sp78Type = FourCharCode(0x73703738)

    /// `fp2e` — signed 16-bit fixed-point with 2 integer + 14 fractional bits
    /// (scale /64, used by some temperature sensors).
    static let fp2eType = FourCharCode(0x66703265)

    /// `fp1a` — signed 16-bit fixed-point with 1 integer + 15 fractional bits
    /// (scale /1024, used by some high-precision temperature sensors).
    static let fp1aType = FourCharCode(0x66703161)

    // MARK: Private State

    /// IOKit connection handle to the AppleSMC service.
    private var connection: io_connect_t = 0

    /// Static reference to the authorization object for admin SMC writes.
    /// Persists for the lifetime of the process once granted.
    static var authRef: AuthorizationRef?

    // MARK: Singleton

    /// Shared singleton instance, created once at app startup.
    static let shared = HardwareMonitor()

    // MARK: - Initialization

    /// Opens the SMC connection and performs an initial data refresh.
    init() {
        open()
        if connection != 0 {
            isAvailable = true
            refresh()
        }
    }

    /// Closes the SMC connection on deallocation.
    deinit {
        close()
    }

    // MARK: - Data Orchestration

    /// Computed property that groups `temperatures` by category for
    /// collapsible UI sections. Empty categories are excluded.
    var groupedTemperatures: [TemperatureGroup] {
        var map: [TemperatureCategory: [TemperatureSensor]] = [:]
        for cat in TemperatureCategory.allCases { map[cat] = [] }
        for sensor in temperatures {
            map[sensor.category]?.append(sensor)
        }
        return TemperatureCategory.allCases.compactMap { cat in
            let sensors = map[cat] ?? []
            return sensors.isEmpty ? nil : TemperatureGroup(category: cat, sensors: sensors)
        }
    }

    /// Refreshes all hardware data: temperatures and fan info.
    /// Called after init and after every fan write operation.
    func refresh() {
        temperatures = readTemperatures()
        fans = readFans()

        // Find the maximum individual P-Core temperature (excluding aggregate rows)
        let cpuTemps = temperatures.filter { $0.category == .cpu && !$0.name.contains("Aggregate") }.map(\.temperature)
        maxCPUTemp = cpuTemps.max() ?? 0
    }

    /// Checks whether the maximum CPU temperature meets or exceeds the
    /// given threshold. If the threshold is newly exceeded, fires
    /// `onThermalThrottle` exactly once.
    func checkThreshold(_ threshold: Double) {
        let wasThrottled = thermalThrottled
        thermalThrottled = maxCPUTemp >= threshold
        if thermalThrottled && !wasThrottled {
            onThermalThrottle?()
        }
    }

    // MARK: - SMC Connection Lifecycle

    /// Opens a connection to the AppleSMC IOKit driver.
    /// Sets `connection` to 0 on failure (no SMC available).
    private func open() {
        let ctx = LogContext(name: "smc.open")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            ctx.fail("未找到 AppleSMC 服务")
            return
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result != kIOReturnSuccess {
            connection = 0
            ctx.fail("打开 SMC 连接失败: \(result)")
        } else {
            ctx.complete(success: true)
        }
    }

    /// Closes the IOKit SMC connection if it is open.
    private func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // MARK: - SMC Read/Write Primitives

    /// Internal buffer returned by `readKeyData()` containing raw bytes,
    /// the SMC data type code, and the byte count.
    internal struct KeyData {
        let bytes: [UInt8]
        let dataType: FourCharCode
        let dataSize: UInt32
    }

    /// Reads the full key info and value for a 4-character SMC key.
    /// Returns `nil` if the key does not exist or the IOKit call fails.
    internal func readKeyData(_ key: String) -> KeyData? {
        guard let fourChar = keyToFourCharCode(key) else { return nil }

        // Step 1: Query key metadata (type, size) via GetKeyInfo
        var input = SMCParamStruct()
        input.key = fourChar
        input.data8 = kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size

        var kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        guard kr == kIOReturnSuccess else { return nil }

        let info = output.keyInfo
        guard info.dataSize > 0, info.dataSize <= 32 else { return nil }

        // Step 2: Read the actual value using the metadata from step 1
        var readInput = SMCParamStruct()
        readInput.key = fourChar
        readInput.keyInfo = info
        readInput.data8 = kSMCReadKey

        var readOutput = SMCParamStruct()
        kr = IOConnectCallStructMethod(connection, 2, &readInput, MemoryLayout<SMCParamStruct>.size, &readOutput, &outSize)
        guard kr == kIOReturnSuccess else { return nil }

        // Copy the raw bytes from the output struct's 32-byte buffer
        var result = [UInt8](repeating: 0, count: Int(info.dataSize))
        withUnsafeBytes(of: &readOutput.bytes) { ptr in
            for i in 0..<Int(info.dataSize) {
                result[i] = ptr[i]
            }
        }
        return KeyData(bytes: result, dataType: info.dataType, dataSize: info.dataSize)
    }

    /// Convenience wrapper: reads raw bytes for a key, discarding type info.
    internal func readBytes(key: String) -> [UInt8]? {
        return readKeyData(key)?.bytes
    }

    /// Writes raw bytes to an SMC key. First queries key info for the
    /// required metadata, then writes the provided data.
    internal func writeBytes(key: String, bytes: UnsafeRawPointer, length: Int) -> Bool {
        guard let fourChar = keyToFourCharCode(key) else { return false }

        // Query key metadata first
        var input = SMCParamStruct()
        input.key = fourChar
        input.data8 = kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size

        var kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        guard kr == kIOReturnSuccess else { return false }

        // Write data using the key info from the query
        var writeInput = SMCParamStruct()
        writeInput.key = fourChar
        writeInput.keyInfo = output.keyInfo
        writeInput.data8 = kSMCWriteKey

        withUnsafeMutableBytes(of: &writeInput.bytes) { ptr in
            for i in 0..<min(length, 32) {
                ptr[i] = bytes.load(fromByteOffset: i, as: UInt8.self)
            }
        }

        kr = IOConnectCallStructMethod(connection, 2, &writeInput, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        return kr == kIOReturnSuccess
    }

    // MARK: - Four-Char Code Helpers

    /// Converts a 4-character string to a Big-Endian `FourCharCode`.
    /// Returns `nil` if the string is not exactly 4 characters.
    internal func keyToFourCharCode(_ key: String) -> FourCharCode? {
        guard key.count == 4 else { return nil }
        let chars = Array(key.utf8)
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 |
               FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }

    /// Converts a 4-character string to a `FourCharCode` (force unwrap).
    internal func fourCharCode(_ str: String) -> FourCharCode {
        let chars = Array(str.utf8)
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 |
               FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }
}
