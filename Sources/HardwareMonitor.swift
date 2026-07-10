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

    func refresh() {
        temperatures = readTemperatures()
        fans = readFans()
    }

    // MARK: - Fan Control

    func setFanMode(fanIndex: Int, auto: Bool) {
        let key = String(format: "F%dMd", fanIndex)
        var value: UInt8 = auto ? 0 : 1
        writeBytes(key: key, bytes: &value, length: 1)
        refresh()
    }

    func setFanSpeed(fanIndex: Int, speed: Double) {
        let key = String(format: "F%dTg", fanIndex)
        var value = UInt16(Int(speed))
        writeBytes(key: key, bytes: &value, length: 2)
        refresh()
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

    private func readBytes(key: String) -> [UInt8]? {
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
        return result
    }

    private func readDataType(key: String) -> FourCharCode? {
        guard let fourChar = keyToFourCharCode(key) else { return nil }

        var input = SMCParamStruct()
        input.key = fourChar
        input.data8 = kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size

        let kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        guard kr == kIOReturnSuccess else { return nil }

        return output.keyInfo.dataType
    }

    private func writeBytes(key: String, bytes: UnsafeRawPointer, length: Int) {
        guard let fourChar = keyToFourCharCode(key) else { return }

        var input = SMCParamStruct()
        input.key = fourChar
        input.data8 = kSMCGetKeyInfo

        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size

        var kr = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        guard kr == kIOReturnSuccess else { return }

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
    }

    // MARK: - Temperature Reading

    private let temperatureKeys: [(key: String, name: String)] = [
        ("TCPU", "CPU"),
        ("TC0C", "CPU Core 0"),
        ("TC1C", "CPU Core 1"),
        ("TC2C", "CPU Core 2"),
        ("TC3C", "CPU Core 3"),
        ("TC4C", "CPU Core 4"),
        ("TC5C", "CPU Core 5"),
        ("TC6C", "CPU Core 6"),
        ("TC7C", "CPU Core 7"),
        ("TC8C", "CPU Core 8"),
        ("TCXC", "CPU Proximity"),
        ("TCXD", "CPU Die"),
        ("TCXE", "CPU Efficiency"),
        ("TG0P", "GPU"),
        ("TG0D", "GPU Die"),
        ("TG0H", "GPU Heatsink"),
        ("TG0M", "GPU Memory"),
        ("TGMR", "GPU Memory"),
        ("TM0P", "Memory"),
        ("TMHD", "Hard Drive"),
        ("TA0P", "Ambient"),
        ("TA1P", "Ambient 2"),
        ("Th0H", "Heatpipe 1"),
        ("Th1H", "Heatpipe 2"),
        ("Th2H", "Heatpipe 3"),
        ("Ts0P", "Palm Rest"),
        ("Ts1P", "Palm Rest 2"),
        ("TB0T", "Battery"),
        ("TW0P", "Airport"),
        ("TP0P", "Power Supply"),
        ("SP0P", "System"),
        ("TS0C", "System Controller"),
        ("SM0P", "SSD"),
        ("SM1P", "SSD 2"),
        ("Tp05", "PCIe SSD"),
        ("Tp0D", "PCIe SSD Die"),
        ("Tp0E", "PCIe SSD Controller"),
        ("Tp0P", "PCIe"),
    ]

    private func readTemperatures() -> [TemperatureSensor] {
        var results: [TemperatureSensor] = []
        for item in temperatureKeys {
            if let value = readTemperature(key: item.key) {
                results.append(TemperatureSensor(key: item.key, name: item.name, temperature: value))
            }
        }
        return results
    }

    private func readTemperature(key: String) -> Double? {
        guard let bytes = readBytes(key: key), bytes.count >= 2 else { return nil }

        let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
        let temp = Double(raw) / 256.0

        guard temp > -128 && temp < 200 else { return nil }
        return temp
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
        guard let bytes = readBytes(key: key), bytes.count >= 2 else { return 0 }

        let dataType = readDataType(key: key)
        let fltType: FourCharCode = fourCharCode("flt ")
        let fdsType: FourCharCode = fourCharCode("{fds")
        let fpe2Type: FourCharCode = fourCharCode("fpe2")
        let sp78Type: FourCharCode = fourCharCode("sp78")

        if dataType == fltType, bytes.count >= 4 {
            let raw = bytes.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Float32.self) }
            return Double(raw)
        } else if dataType == fdsType {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 4.0
        } else if dataType == fpe2Type {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 4.0
        } else if dataType == sp78Type {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
            return Double(raw) / 256.0
        } else {
            let raw = Int16(bytes[0]) << 8 | Int16(bytes[1])
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
