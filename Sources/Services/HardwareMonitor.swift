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

    /// 5-second rolling average of maxCPUTemp (smoothed to avoid spike false triggers).
    @Published var smoothedCPUTemp: Double = 0

    private var cpuTempBuffer: [Double] = []
    private let cpuTempBufferSize = 5

    /// Whether the Mac is currently running on battery power.
    /// Updated by AppDelegate from BatteryMonitor's state.
    /// Used by views to reduce polling frequency on battery.
    @Published var isRunningOnBattery = false

    /// Whether admin authorization has been granted for SMC writes.
    @Published var isAdminAuthorized = false

    // MARK: Callbacks

    /// Called once when `thermalThrottled` transitions from false to true.
    /// Called when CPU temperature first exceeds the threshold.
    /// The handler should release fan control to the system (auto mode).
    var onThermalThrottle: (() -> Void)?

    /// Called when CPU temperature drops back below the threshold.
    /// The handler should restore the user's previous fan settings.
    var onThermalCooldown: (() -> Void)?

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

    /// Cache of SMC key metadata (type, data size) keyed by 4-char key string.
    /// Key metadata never changes at runtime, so we query it once per key then
    /// reuse. This eliminates one IOConnectCallStructMethod per key per read.
    private var keyInfoCache: [String: SMCKeyInfoData] = [:]

    /// Guards against overlapping `refresh()` calls. Set to `true` before
    /// dispatching to the background queue and reset to `false` on the main
    /// thread after publishing. Timer ticks that arrive during a slow SMC
    /// read cycle are silently skipped.
    private var isRefreshing = false

    /// Cursor into `validTempKeysCache`. Each `partialRefresh()` call reads
    /// exactly ONE key at this index, advancing by 1. When the cursor wraps
    /// past the last key, accumulated results are published as a batch and
    /// the cycle restarts.
    private var tempCursor = 0

    /// Accumulator for staggered temperature reads. `partialRefresh()` adds
    /// each sensor reading here. At cycle end (cursor wraps), the full batch
    /// is published and the accumulator is reset.
    private var tempAccumulator: [TemperatureSensor] = []

    /// Cursor into the CPU/GPU-filtered key list. Each `partialRefreshCPUAndGPU()`
    /// call reads `partialBatchSize` keys at this index, advancing by batchSize.
    /// When the cursor wraps, accumulated results are published.
    private var cpuGpuCursor = 0

    /// Accumulator for CPU/GPU-only staggered reads. `partialRefreshCPUAndGPU()`
    /// adds each sensor here. At cycle end, the full batch is published.
    private var cpuGpuAccumulator: [TemperatureSensor] = []

    /// Static reference to the authorization object for admin SMC writes.
    /// Persists for the lifetime of the process once granted.
    static var authRef: AuthorizationRef?

    /// Whether the user explicitly denied (or cancelled) the admin auth dialog.
    /// When `true`, `requestAdminAuth()` returns `false` without showing the
    /// dialog. Reset by `resetAuthDenied()` before explicit user-initiated retries.
    static var authDenied = false

    /// Whether an auth request is currently in flight. Prevents showing more
    /// than one auth dialog simultaneously. Reset after the dialog completes.
    static var authInProgress = false

    /// Resets the denied state so the next `requestAdminAuth()` call will
    /// actually show the auth dialog. Call this ONLY before explicit user
    /// actions (button taps), NOT before automatic/derived calls.
    static func resetAuthDenied() {
        authDenied = false
    }

    // MARK: Singleton

    /// Shared singleton instance, created once at app startup.
    static let shared = HardwareMonitor()

    // MARK: - Initialization

    /// Does NOT open the SMC connection eagerly. SMC is opened lazily
    /// on the first read/write operation. This avoids IOKit overhead
    /// for users who only use BatKill for power management and never
    /// open the hardware monitor window.
    init() {
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
    /// Reads SMC on a background queue to avoid blocking the main thread,
    /// then publishes results on the main thread for @Published safety.
    ///
    /// Guarded by `isRefreshing` to skip overlapping calls when the timer
    /// fires before a slow SMC read completes.
    ///
    /// Called after init and after fan write operations (full data needed).
    func refresh() {
        lazyEnsureOpen()
        guard connection != 0 else { return }
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let temps = self.readTemperatures()
            let fans = self.readFans()
            let cpuTemps = temps.filter { $0.category == .cpu && !$0.name.contains("Aggregate") }.map(\.temperature)
            let maxTemp = cpuTemps.max() ?? 0
            DispatchQueue.main.async {
                self.temperatures = temps
                self.fans = fans
                self.maxCPUTemp = maxTemp
                self.updateSmoothedCPUTemp(maxTemp)
                self.isRefreshing = false
            }
        }
    }

    /// Staggered temperature read: reads exactly ONE SMC temperature key
    /// per call, spreading ~15-25 kernel traps across ~8 seconds instead of
    /// firing them all in one 50ms burst. The timer calls this every 400ms.
    ///
    /// At cycle end (cursor wraps past last key), accumulated results are
    /// batch-published to SwiftUI for a single render pass.
    ///
    /// Falls back to a full `readTemperatures()` scan if the key cache has
    /// not been populated yet (first call after launch).
    private var partialBatchSize: Int {
        #if arch(arm64)
        return 2
        #else
        return 1
        #endif
    }

    func partialRefresh(threshold: Double? = nil) {
        lazyEnsureOpen()
        guard connection != 0 else { return }
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            guard let keys = HardwareMonitor.validTempKeysCache, !keys.isEmpty else {
                let temps = self.readTemperatures()
                let cachedFans = self.fans
                DispatchQueue.main.async {
                    self.temperatures = temps
                    self.fans = cachedFans
                    self.isRefreshing = false
                }
                return
            }

            let batchSize = self.partialBatchSize
            for _ in 0..<batchSize {
                let idx = self.tempCursor
                let item = keys[idx]
                if let sensor = self.readTempSensor(key: item.key, name: item.name, category: item.category) {
                    if let existing = self.tempAccumulator.firstIndex(where: { $0.key == sensor.key }) {
                        self.tempAccumulator[existing] = sensor
                    } else {
                        self.tempAccumulator.append(sensor)
                    }
                }
                self.tempCursor = (idx + 1) % keys.count
                if self.tempCursor == 0 { break }
            }

            if self.tempCursor == 0 {
                let pCoreTemps = self.tempAccumulator
                    .filter { $0.name.hasPrefix("CPU P-Core ") && !$0.name.contains("Aggregate") }
                    .map(\.temperature)
                let maxTemp = pCoreTemps.max() ?? 0
                let cachedFans = self.fans
                let batch = self.tempAccumulator

                self.tempAccumulator = []

                DispatchQueue.main.async {
                    self.temperatures = batch
                    self.fans = cachedFans
                    self.maxCPUTemp = maxTemp
                    self.updateSmoothedCPUTemp(maxTemp)
                    self.isRefreshing = false
                    if let threshold { self.checkThreshold(threshold) }
                }
            } else {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                }
            }
        }
    }

    /// CPU/GPU-only staggered read: reads `partialBatchSize` CPU/GPU temperature
    /// keys per call, skipping memory/battery/storage/ambient/other sensors.
    /// Used when the temperature window is in the background — reduces SMC
    /// kernel traps while still providing real-time CPU/GPU temperature updates.
    func partialRefreshCPUAndGPU(threshold: Double? = nil) {
        lazyEnsureOpen()
        guard connection != 0 else { return }
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            guard let keys = HardwareMonitor.validTempKeysCache, !keys.isEmpty else {
                let temps = self.readTemperatures()
                let cachedFans = self.fans
                DispatchQueue.main.async {
                    self.temperatures = temps
                    self.fans = cachedFans
                    self.isRefreshing = false
                }
                return
            }

            let cpuGpuKeys = keys.filter { $0.category == .cpu || $0.category == .gpu }
            guard !cpuGpuKeys.isEmpty else {
                DispatchQueue.main.async { self.isRefreshing = false }
                return
            }

            let batchSize = self.partialBatchSize
            for _ in 0..<batchSize {
                let idx = self.cpuGpuCursor
                let item = cpuGpuKeys[idx]
                if let sensor = self.readTempSensor(key: item.key, name: item.name, category: item.category) {
                    if let existing = self.cpuGpuAccumulator.firstIndex(where: { $0.key == sensor.key }) {
                        self.cpuGpuAccumulator[existing] = sensor
                    } else {
                        self.cpuGpuAccumulator.append(sensor)
                    }
                }
                self.cpuGpuCursor = (idx + 1) % cpuGpuKeys.count
                if self.cpuGpuCursor == 0 { break }
            }

            if self.cpuGpuCursor == 0 {
                let pCoreTemps = self.cpuGpuAccumulator
                    .filter { $0.name.hasPrefix("CPU P-Core ") && !$0.name.contains("Aggregate") }
                    .map(\.temperature)
                let maxTemp = pCoreTemps.max() ?? 0
                let cachedFans = self.fans
                let batch = self.cpuGpuAccumulator

                self.cpuGpuAccumulator = []

                DispatchQueue.main.async {
                    self.temperatures = batch
                    self.fans = cachedFans
                    self.maxCPUTemp = maxTemp
                    self.updateSmoothedCPUTemp(maxTemp)
                    self.isRefreshing = false
                    if let threshold { self.checkThreshold(threshold) }
                }
            } else {
                DispatchQueue.main.async {
                    self.isRefreshing = false
                }
            }
        }
    }

    /// Fast temperature read: reads ALL sensors in one background cycle,
    /// then publishes immediately. Used when the temperature window is open
    /// to provide real-time updates at ~1s intervals.
    func fastRefresh(threshold: Double? = nil) {
        lazyEnsureOpen()
        guard connection != 0 else { return }
        if isRefreshing { return }
        isRefreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let temps = self.readTemperatures()
            let cpuTemps = temps
                .filter { $0.category == .cpu && !$0.name.contains("Aggregate") }
                .map(\.temperature)
            let maxTemp = cpuTemps.max() ?? 0
            let cachedFans = self.fans
            DispatchQueue.main.async {
                self.temperatures = temps
                self.fans = cachedFans
                self.maxCPUTemp = maxTemp
                self.updateSmoothedCPUTemp(maxTemp)
                self.isRefreshing = false
                if let threshold {
                    self.checkThreshold(threshold)
                }
            }
        }
    }

    /// Checks whether the maximum CPU temperature meets or exceeds the
    /// given threshold. Fires `onThermalThrottle` when the threshold is
    /// newly exceeded, and `onThermalCooldown` when the CPU cools back
    /// below it.
    func checkThreshold(_ threshold: Double) {
        let wasThrottled = thermalThrottled
        thermalThrottled = smoothedCPUTemp >= threshold
        if thermalThrottled && !wasThrottled {
            onThermalThrottle?()
        } else if !thermalThrottled && wasThrottled {
            onThermalCooldown?()
        }
    }

    private func updateSmoothedCPUTemp(_ value: Double) {
        cpuTempBuffer.append(value)
        if cpuTempBuffer.count > cpuTempBufferSize {
            cpuTempBuffer.removeFirst()
        }
        smoothedCPUTemp = cpuTempBuffer.reduce(0, +) / Double(cpuTempBuffer.count)
    }

    // MARK: - SMC Connection Lifecycle

    /// Ensures the SMC connection is open. Call this before every
    /// read/write operation. No-op if already connected.
    /// Sets `isAvailable` based on connection success.
    private func lazyEnsureOpen() {
        guard connection == 0 else { return }
        open()
        isAvailable = connection != 0
    }

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
    ///
    /// Optimisation: key metadata (type, data size) is cached after the first
    /// read since it never changes at runtime. This eliminates the `kSMCGetKeyInfo`
    /// IOConnect call (~50% of per-key kernel traps) on subsequent reads.
    internal func readKeyData(_ key: String) -> KeyData? {
        lazyEnsureOpen()
        guard connection != 0 else { return nil }
        guard let fourChar = keyToFourCharCode(key) else { return nil }

        // Step 1: Query key metadata — use cache if available
        let info: SMCKeyInfoData
        if let cached = keyInfoCache[key] {
            info = cached
        } else {
            var getInput = SMCParamStruct()
            getInput.key = fourChar
            getInput.data8 = kSMCGetKeyInfo

            var getOutput = SMCParamStruct()
            var outSize = MemoryLayout<SMCParamStruct>.size

            let kr = IOConnectCallStructMethod(
                connection, 2,
                &getInput, MemoryLayout<SMCParamStruct>.size,
                &getOutput, &outSize
            )
            guard kr == kIOReturnSuccess else { return nil }
            guard getOutput.keyInfo.dataSize > 0, getOutput.keyInfo.dataSize <= 32 else { return nil }

            info = getOutput.keyInfo
            keyInfoCache[key] = info
        }

        // Step 2: Read the actual value using the (cached or just-fetched) metadata
        var readInput = SMCParamStruct()
        readInput.key = fourChar
        readInput.keyInfo = info
        readInput.data8 = kSMCReadKey

        var readOutput = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size
        let kr = IOConnectCallStructMethod(
            connection, 2,
            &readInput, MemoryLayout<SMCParamStruct>.size,
            &readOutput, &outSize
        )
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

    /// Writes raw bytes to an SMC key. Uses the cached key metadata
    /// if available (from a previous read), otherwise queries and caches it.
    /// This eliminates one IOConnectCallStructMethod per key when the
    /// metadata was already cached by a prior readKeyData() call.
    internal func writeBytes(key: String, bytes: UnsafeRawPointer, length: Int) -> Bool {
        lazyEnsureOpen()
        guard connection != 0 else { return false }
        guard let fourChar = keyToFourCharCode(key) else { return false }

        // Use cached key metadata if available (avoids redundant IOConnect call)
        let info: SMCKeyInfoData
        if let cached = keyInfoCache[key] {
            info = cached
        } else {
            var getInput = SMCParamStruct()
            getInput.key = fourChar
            getInput.data8 = kSMCGetKeyInfo

            var getOutput = SMCParamStruct()
            var outSize = MemoryLayout<SMCParamStruct>.size

            let kr = IOConnectCallStructMethod(
                connection, 2,
                &getInput, MemoryLayout<SMCParamStruct>.size,
                &getOutput, &outSize
            )
            guard kr == kIOReturnSuccess else { return false }
            info = getOutput.keyInfo
            keyInfoCache[key] = info
        }

        // Write data using the (cached or just-fetched) key info
        var writeInput = SMCParamStruct()
        writeInput.key = fourChar
        writeInput.keyInfo = info
        writeInput.data8 = kSMCWriteKey

        withUnsafeMutableBytes(of: &writeInput.bytes) { ptr in
            for i in 0..<min(length, 32) {
                ptr[i] = bytes.load(fromByteOffset: i, as: UInt8.self)
            }
        }

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size
        let writeKr = IOConnectCallStructMethod(connection, 2, &writeInput, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        return writeKr == kIOReturnSuccess
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
