import Foundation
import IOKit

// MARK: - SMC Data Structures
private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: FourCharCode = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCParamStruct {
    var key: FourCharCode = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0)
    var pLimitData: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var dataTypeIndex: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

private let kSMCReadKey: UInt8 = 5
private let kSMCWriteKey: UInt8 = 6
private let kSMCGetKeyInfo: UInt8 = 9

// MARK: - Public Models
struct TemperatureSensor: Identifiable {
    let id = UUID()
    let key: String
    let name: String
    let temperature: Double
    let category: TemperatureCategory
}

enum TemperatureCategory: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case memory = "Memory"
    case battery = "Battery"
    case storage = "Storage"
    case ambient = "Ambient"
    case other = "Other"

    var id: String { rawValue }

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

struct TemperatureGroup: Identifiable {
    let category: TemperatureCategory
    let sensors: [TemperatureSensor]

    var id: TemperatureCategory { category }

    var average: Double {
        guard !sensors.isEmpty else { return 0 }
        return sensors.map(\.temperature).reduce(0, +) / Double(sensors.count)
    }
}

struct FanInfo: Identifiable {
    let id = UUID()
    let index: Int
    let name: String
    let minSpeed: Double
    let maxSpeed: Double
    let currentSpeed: Double
    let isAutoMode: Bool
}

// MARK: - HardwareMonitor
final class HardwareMonitor: ObservableObject {
    @Published var temperatures: [TemperatureSensor] = []
    @Published var fans: [FanInfo] = []
    @Published var isAvailable = false
    @Published var lastFanWriteOK = false

    private var connection: io_connect_t = 0

    static let shared = HardwareMonitor()

    init() {
        open()
        if connection != 0 {
            isAvailable = true
            refresh()
        }
    }

    deinit {
        close()
    }

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

    func refresh() {
        temperatures = readTemperatures()
        fans = readFans()
    }

    // MARK: - Fan Control

    func setFanMode(fanIndex: Int, auto: Bool) {
        let key = String(format: "F%dMd", fanIndex)
        var value: UInt8 = auto ? 0 : 1
        let ok = writeBytes(key: key, bytes: &value, length: 1)
        lastFanWriteOK = ok
        refresh()
    }

    func setFanSpeed(fanIndex: Int, speed: Double) -> Bool {
        let ok = writeFanTarget(fanIndex: fanIndex, speed: speed)
        lastFanWriteOK = ok
        refresh()
        return ok
    }

    private func writeFanTarget(fanIndex: Int, speed: Double) -> Bool {
        let key = String(format: "F%dTg", fanIndex)
        var value = UInt16(clamping: Int(speed))
        return writeBytes(key: key, bytes: &value, length: 2)
    }

    // MARK: - Admin Fan Control

    func setFanSpeedWithAdmin(fanIndex: Int, speed: Double) -> Bool {
        let execPath = CommandLine.arguments[0]
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = [execPath, "--set-fan", "\(fanIndex)", "\(Int(speed))"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let ok = task.terminationStatus == 0
            if ok { refresh() }
            lastFanWriteOK = ok
            return ok
        } catch {
            logger("setFanSpeedWithAdmin failed: \(error)")
            lastFanWriteOK = false
            return false
        }
    }

    // MARK: - SMC Connection

    private func open() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        if result != kIOReturnSuccess {
            connection = 0
        }
    }

    private func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // MARK: - SMC Read/Write

    private struct KeyData {
        let bytes: [UInt8]
        let dataType: FourCharCode
        let dataSize: UInt32
    }

    private func readKeyData(_ key: String) -> KeyData? {
        guard let fourChar = keyToFourCharCode(key) else { return nil }

        var input = SMCParamStruct()
        input.key = fourChar
        input.data8 = kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size

        var kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        guard kr == kIOReturnSuccess else { return nil }

        let info = output.keyInfo
        guard info.dataSize > 0, info.dataSize <= 32 else { return nil }

        var readInput = SMCParamStruct()
        readInput.key = fourChar
        readInput.keyInfo = info
        readInput.data8 = kSMCReadKey

        var readOutput = SMCParamStruct()
        kr = IOConnectCallStructMethod(connection, 2, &readInput, MemoryLayout<SMCParamStruct>.size, &readOutput, &outSize)
        guard kr == kIOReturnSuccess else { return nil }

        var result = [UInt8](repeating: 0, count: Int(info.dataSize))
        withUnsafeBytes(of: &readOutput.bytes) { ptr in
            for i in 0..<Int(info.dataSize) {
                result[i] = ptr[i]
            }
        }
        return KeyData(bytes: result, dataType: info.dataType, dataSize: info.dataSize)
    }

    private func readBytes(key: String) -> [UInt8]? {
        return readKeyData(key)?.bytes
    }

    private func writeBytes(key: String, bytes: UnsafeRawPointer, length: Int) -> Bool {
        guard let fourChar = keyToFourCharCode(key) else { return false }

        var input = SMCParamStruct()
        input.key = fourChar
        input.data8 = kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size

        var kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        guard kr == kIOReturnSuccess else { return false }

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

    // MARK: - Temperature Reading

    private static let fltType  = FourCharCode(0x666C7420)
    private static let fdsType  = FourCharCode(0x7B666473)
    private static let fpe2Type = FourCharCode(0x66706532)
    private static let sp78Type = FourCharCode(0x73703738)
    private static let fp2eType = FourCharCode(0x66703265)
    private static let fp1aType = FourCharCode(0x66703161)

    private let knownTempKeys: [(key: String, name: String, category: TemperatureCategory)] = [
        ("Tp01", "CPU P-Core 1",        .cpu),
        ("Tp05", "CPU P-Core 5",        .cpu),
        ("Tp09", "CPU P-Core 9",        .cpu),
        ("Tp0D", "CPU P-Core 13",       .cpu),
        ("Tp0E", "CPU Die",             .cpu),
        ("Tp0F", "CPU P-Core",          .cpu),
        ("Tp0b", "CPU E-Core",          .cpu),
        ("Tp01", "CPU Performance 1",   .cpu),
        ("TCPU", "CPU Package",         .cpu),
        ("TC0C", "CPU Core 0",          .cpu),
        ("TC1C", "CPU Core 1",          .cpu),
        ("TC2C", "CPU Core 2",          .cpu),
        ("TC3C", "CPU Core 3",          .cpu),
        ("TC4C", "CPU Core 4",          .cpu),
        ("TC5C", "CPU Core 5",          .cpu),
        ("TC6C", "CPU Core 6",          .cpu),
        ("TC7C", "CPU Core 7",          .cpu),
        ("TC8C", "CPU Core 8",          .cpu),
        ("TCXC", "CPU Proximity",       .cpu),
        ("TCXD", "CPU Die",             .cpu),
        ("TCXE", "CPU Efficiency",      .cpu),
        ("TCXF", "CPU Performance",     .cpu),
        ("Tg05", "GPU",                 .gpu),
        ("TG0P", "GPU Package",         .gpu),
        ("TG0D", "GPU Die",             .gpu),
        ("TG0H", "GPU Heatsink",        .gpu),
        ("TG0M", "GPU Memory",          .gpu),
        ("TGMR", "GPU Memory",          .gpu),
        ("TM0P", "Memory Proximity",    .memory),
        ("TM0S", "Memory Slot",         .memory),
        ("TM8S", "Memory Slot 2",       .memory),
        ("Tm01", "Memory 1",            .memory),
        ("Tm02", "Memory 2",            .memory),
        ("TB0T", "Battery",             .battery),
        ("TB1T", "Battery 1",           .battery),
        ("TB2T", "Battery 2",           .battery),
        ("Ts0S", "SSD",                 .storage),
        ("SM0P", "SSD Proximity",       .storage),
        ("SM1P", "SSD 2",               .storage),
        ("Ts0P", "SSD 0",               .storage),
        ("Ts1P", "SSD 1",               .storage),
        ("TA0P", "Ambient",             .ambient),
        ("TA1P", "Ambient 2",           .ambient),
        ("Ta0P", "Ambient Alt",         .ambient),
        ("TH00", "Heatpipe 1",          .ambient),
        ("TH01", "Heatpipe 2",          .ambient),
        ("TH02", "Heatpipe 3",          .ambient),
        ("TW0P", "WiFi",                .other),
        ("TP0P", "Power Supply",        .other),
        ("SP0P", "System",              .other),
        ("TS0C", "System Controller",   .other),
    ]

    private func readTemperatures() -> [TemperatureSensor] {
        var seen = Set<String>()
        var results: [TemperatureSensor] = []

        for item in knownTempKeys {
            guard !seen.contains(item.key) else { continue }
            if let sensor = readTempSensor(key: item.key, name: item.name, category: item.category) {
                seen.insert(item.key)
                results.append(sensor)
            }
        }

        let discovered = discoverTemperatureKeys(excluding: seen)
        for (key, data) in discovered {
            let (name, category) = classifyTempKey(key)
            if let sensor = decodeTempFromData(data, key: key, name: name, category: category) {
                results.append(sensor)
            }
        }

        return results
    }

    private func discoverTemperatureKeys(excluding known: Set<String>) -> [(String, KeyData)] {
        var results: [(String, KeyData)] = []
        let prefixes: [Character] = ["T"]
        let secondChars: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

        for prefix in prefixes {
            for c2 in secondChars {
                for i1 in 0...9 {
                    for i2 in 0...9 {
                        let key = "\(prefix)\(c2)\(i1)\(i2)"
                        guard !known.contains(key) else { continue }
                        guard let data = readKeyData(key) else { continue }
                        guard data.dataSize == 2 || data.dataSize == 4 else { continue }
                        guard isTempType(data.dataType) else { continue }
                        results.append((key, data))
                    }
                }
            }
        }
        return results
    }

    private func isTempType(_ dataType: FourCharCode) -> Bool {
        return dataType == HardwareMonitor.fltType
            || dataType == HardwareMonitor.fdsType
            || dataType == HardwareMonitor.fpe2Type
            || dataType == HardwareMonitor.sp78Type
            || dataType == HardwareMonitor.fp2eType
            || dataType == HardwareMonitor.fp1aType
    }

    private func classifyTempKey(_ key: String) -> (String, TemperatureCategory) {
        let second = key.count > 1 ? key[key.index(key.startIndex, offsetBy: 1)] : " "
        switch second {
        case "C", "c": return (friendlyKeyName(key), .cpu)
        case "G", "g": return (friendlyKeyName(key), .gpu)
        case "M", "m": return (friendlyKeyName(key), .memory)
        case "B", "b": return (friendlyKeyName(key), .battery)
        case "S", "s": return (friendlyKeyName(key), .storage)
        case "A", "a": return (friendlyKeyName(key), .ambient)
        case "W", "w": return (friendlyKeyName(key), .other)
        case "P", "p":
            if key.hasPrefix("Tp") { return (friendlyKeyName(key), .cpu) }
            return (friendlyKeyName(key), .other)
        default: return (friendlyKeyName(key), .other)
        }
    }

    private func friendlyKeyName(_ key: String) -> String {
        let prefix: String
        let second = key.count > 1 ? String(key[key.index(key.startIndex, offsetBy: 1)]) : ""
        switch second {
        case "C", "c": prefix = "CPU"
        case "G", "g": prefix = "GPU"
        case "M", "m": prefix = "MEM"
        case "B", "b": prefix = "BAT"
        case "S", "s": prefix = "SSD"
        case "A", "a": prefix = "AMB"
        case "W", "w": prefix = "WiFi"
        case "P", "p": prefix = key.hasPrefix("Tp") ? "CPU" : "PWR"
        case "H", "h": prefix = "HEAT"
        case "T", "t": prefix = "TS"
        default: prefix = key
        }
        return "\(prefix) \(key.suffix(2))"
    }

    private func readTempSensor(key: String, name: String, category: TemperatureCategory) -> TemperatureSensor? {
        guard let data = readKeyData(key) else { return nil }
        guard isTempType(data.dataType) else { return nil }
        return decodeTempFromData(data, key: key, name: name, category: category)
    }

    private func decodeTempFromData(_ data: KeyData, key: String, name: String, category: TemperatureCategory) -> TemperatureSensor? {
        let temp = decodeTemperature(bytes: data.bytes, dataType: data.dataType)
        guard temp > -40 && temp < 150 else { return nil }
        return TemperatureSensor(key: key, name: name, temperature: temp, category: category)
    }

    private func decodeTemperature(bytes: [UInt8], dataType: FourCharCode) -> Double {
        if dataType == HardwareMonitor.fltType, bytes.count >= 4 {
            let raw = bytes.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float32.self) }
            return Double(raw)
        } else if dataType == HardwareMonitor.sp78Type, bytes.count >= 2 {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 256.0
        } else if dataType == HardwareMonitor.fdsType, bytes.count >= 2 {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 4.0
        } else if dataType == HardwareMonitor.fpe2Type, bytes.count >= 2 {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 64.0
        } else if dataType == HardwareMonitor.fp2eType, bytes.count >= 2 {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 64.0
        } else if dataType == HardwareMonitor.fp1aType, bytes.count >= 2 {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 1024.0
        } else if bytes.count >= 2 {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 256.0
        }
        return 0
    }

    // MARK: - Fan Reading

    private func readFans() -> [FanInfo] {
        guard let countBytes = readBytes(key: "FNum"), let count = countBytes.first, count > 0 else {
            return []
        }

        var results: [FanInfo] = []
        for i in 0..<Int(count) {
            let name = readFanString(key: String(format: "F%dNm", i)) ?? "Fan \(i)"
            let minSpeed = readFanSpeed(key: String(format: "F%dMn", i))
            let maxSpeed = readFanSpeed(key: String(format: "F%dMx", i))
            let currentSpeed = readFanSpeed(key: String(format: "F%dAc", i))
            let modeBytes = readBytes(key: String(format: "F%dMd", i))
            let isAuto = modeBytes?.first == 0

            results.append(FanInfo(
                index: i,
                name: name,
                minSpeed: minSpeed,
                maxSpeed: maxSpeed,
                currentSpeed: currentSpeed,
                isAutoMode: isAuto
            ))
        }
        return results
    }

    private func readFanSpeed(key: String) -> Double {
        guard let data = readKeyData(key), data.bytes.count >= 2 else { return 0 }
        let dataType = data.dataType

        if dataType == HardwareMonitor.fltType, data.bytes.count >= 4 {
            let raw = data.bytes.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float32.self) }
            return Double(raw)
        } else if dataType == HardwareMonitor.fdsType {
            let raw = Int16(data.bytes[0]) << 8 | Int16(data.bytes[1])
            return Double(raw) / 4.0
        } else if dataType == HardwareMonitor.fpe2Type {
            let raw = Int16(data.bytes[0]) << 8 | Int16(data.bytes[1])
            return Double(raw) / 4.0
        } else {
            let raw = Int(data.bytes[0]) << 8 | Int(data.bytes[1])
            return Double(raw)
        }
    }

    private func readFanString(key: String) -> String? {
        guard let bytes = readBytes(key: key) else { return nil }
        let trimmed = bytes.filter { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8)
    }

    // MARK: - Helpers

    private func keyToFourCharCode(_ key: String) -> FourCharCode? {
        guard key.count == 4 else { return nil }
        let chars = Array(key.utf8)
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 |
               FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }

    private func fourCharCode(_ str: String) -> FourCharCode {
        let chars = Array(str.utf8)
        return FourCharCode(chars[0]) << 24 | FourCharCode(chars[1]) << 16 |
               FourCharCode(chars[2]) << 8 | FourCharCode(chars[3])
    }
}
