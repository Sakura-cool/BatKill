import Foundation
import IOKit
import Security

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

    // MARK: - Fan Control (direct SMC, no admin)

    func setFanMode(fanIndex: Int, auto: Bool) -> Bool {
        let key = String(format: "F%dMd", fanIndex)
        var value: UInt8 = auto ? 0 : 1
        let ok = writeBytes(key: key, bytes: &value, length: 1)
        lastFanWriteOK = ok
        refresh()
        return ok
    }

    func setFanSpeed(fanIndex: Int, speed: Double) -> Bool {
        let ok = writeFanTarget(fanIndex: fanIndex, speed: speed)
        lastFanWriteOK = ok
        refresh()
        return ok
    }

    private func writeFanTarget(fanIndex: Int, speed: Double) -> Bool {
        let key = String(format: "F%dTg", fanIndex)
        guard let data = readKeyData(key) else { return false }

        if data.dataType == HardwareMonitor.fpe2Type {
            var value = UInt16(clamping: Int(speed * 4))
            return writeBytes(key: key, bytes: &value, length: 2)
        } else if data.dataType == HardwareMonitor.fltType {
            var value = Float32(speed)
            return writeBytes(key: key, bytes: &value, length: 4)
        } else {
            var value = UInt16(clamping: Int(speed))
            return writeBytes(key: key, bytes: &value, length: 2)
        }
    }

    // MARK: - Admin Fan Control (one-time auth via AuthorizationServices)

    private static var authRef: AuthorizationRef?
    @Published var isAdminAuthorized = false

    func requestAdminAuth() -> Bool {
        if HardwareMonitor.authRef != nil {
            isAdminAuthorized = true
            return true
        }

        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess,
              let ref = ref else { return false }

        let rightName = kAuthorizationRightExecute
        return rightName.withCString { cName in
            var item = AuthorizationItem(name: cName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.preAuthorize, .extendRights, .interactionAllowed]

                if AuthorizationCopyRights(ref, &rights, nil, flags, nil) == errAuthorizationSuccess {
                    HardwareMonitor.authRef = ref
                    isAdminAuthorized = true
                    return true
                }

                AuthorizationFree(ref, [.destroyRights])
                return false
            }
        }
    }

    func runWithAdmin(args: [String], completion: @escaping (Bool) -> Void) {
        guard let authRef = HardwareMonitor.authRef,
              let execPath = Bundle.main.executablePath else {
            completion(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var cArgs = args.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }

            typealias AuthExecFunc = @convention(c) (
                AuthorizationRef, UnsafePointer<CChar>, AuthorizationFlags,
                UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
                ((UnsafeMutableRawPointer?) -> Void)?
            ) -> OSStatus

            let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)
            if let sym = dlsym(handle, "AuthorizationExecuteWithPrivileges") {
                let exec = unsafeBitCast(sym, to: AuthExecFunc.self)
            cArgs.withUnsafeMutableBufferPointer { buf in
                exec(authRef, execPath, [], buf.baseAddress, nil)
            }
            }

            DispatchQueue.main.async {
                self?.refresh()
                completion(true)
            }
        }
    }

    func setFanModeWithAdmin(fanIndex: Int, auto: Bool, completion: @escaping (Bool) -> Void) {
        let mode = auto ? 0 : 1
        runWithAdmin(args: ["--set-fan-mode", "\(fanIndex)", "\(mode)"], completion: completion)
    }

    func setFanSpeedWithAdmin(fanIndex: Int, speed: Double, completion: @escaping (Bool) -> Void) {
        runWithAdmin(args: ["--set-fan", "\(fanIndex)", "\(Int(speed))"], completion: completion)
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

    // Apple Silicon temperature keys - names generated from actual CPU topology
    // Tp01-Tp05: P-core sensors (one per P-core)
    // Tp06-Tp07: E-core sensors (one per E-core)
    // Tp08-Tp09: Additional P-core sensors
    // Tp0A-Tp0D: Additional E-core sensors
    // Tp0E: CPU Die
    // Tp0F: CPU aggregate
    // Tp0b: E-Core aggregate
    
    private var appleSiliconKeys: [(key: String, name: String, category: TemperatureCategory)] {
        let pCores = Int(getSysctlInt("hw.perflevel0.physicalcpu"))
        let eCores = Int(getSysctlInt("hw.perflevel1.physicalcpu"))
        
        var keys: [(key: String, name: String, category: TemperatureCategory)] = []
        var pIndex = 0, eIndex = 0
        
        for i in 1...0x0D {
            let hex = String(format: "%X", i)
            let key = "Tp0\(hex)"
            
            if key == "Tp03" || key == "Tp07" { continue }
            
            if pIndex < pCores {
                keys.append((key, "CPU P-Core \(pIndex + 1)", .cpu))
                pIndex += 1
            } else if eIndex < eCores {
                keys.append((key, "CPU E-Core \(eIndex + 1)", .cpu))
                eIndex += 1
            }
        }
        
        keys.append(("Tp0E", "CPU Die", .cpu))
        keys.append(("Tp0b", "CPU E-Core Aggregate", .cpu))
        
        return keys
    }
    
    private let intelTempKeys: [(key: String, name: String, category: TemperatureCategory)] = [
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
    ]
    
    // Common keys for both Intel and Apple Silicon
    private let commonTempKeys: [(key: String, name: String, category: TemperatureCategory)] = [
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
    
    private var knownTempKeys: [(key: String, name: String, category: TemperatureCategory)] {
        let isAppleSilicon = getSysctlInt("hw.optional.arm64") == 1
        if isAppleSilicon {
            return appleSiliconKeys + commonTempKeys
        } else {
            return intelTempKeys + commonTempKeys
        }
    }
    
    private func getSysctlInt(_ name: String) -> Int32 {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    private func readTemperatures() -> [TemperatureSensor] {
        var seen = Set<String>()
        var results: [TemperatureSensor] = []
        var pCoreTemps: [Double] = []

        for item in knownTempKeys {
            guard !seen.contains(item.key) else { continue }
            if let sensor = readTempSensor(key: item.key, name: item.name, category: item.category) {
                seen.insert(item.key)
                results.append(sensor)
                if sensor.name.hasPrefix("CPU P-Core ") && !sensor.name.contains("Aggregate") {
                    pCoreTemps.append(sensor.temperature)
                }
            }
        }

        if !pCoreTemps.isEmpty {
            let avg = pCoreTemps.reduce(0, +) / Double(pCoreTemps.count)
            results.append(TemperatureSensor(key: "AGG_P", name: "CPU P-Core Aggregate", temperature: avg, category: .cpu))
        }

        return results
    }

    private func isTempType(_ dataType: FourCharCode) -> Bool {
        dataType == HardwareMonitor.fltType
            || dataType == HardwareMonitor.fdsType
            || dataType == HardwareMonitor.fpe2Type
            || dataType == HardwareMonitor.sp78Type
            || dataType == HardwareMonitor.fp2eType
            || dataType == HardwareMonitor.fp1aType
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
