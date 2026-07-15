import Foundation

extension HardwareMonitor {

    var appleSiliconKeys: [(key: String, name: String, category: TemperatureCategory)] {
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

    var intelTempKeys: [(key: String, name: String, category: TemperatureCategory)] {
        [
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
    }

    var commonTempKeys: [(key: String, name: String, category: TemperatureCategory)] {
        [
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
    }

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

    /// Cached list of SMC keys that exist on this hardware.
    /// Populated on first read, then reused for subsequent reads.
    /// `internal` visibility for `partialRefresh()` in HardwareMonitor.swift.
    static var validTempKeysCache: [(key: String, name: String, category: TemperatureCategory)]?

    func readTemperatures() -> [TemperatureSensor] {
        var seen = Set<String>()
        var results: [TemperatureSensor] = []
        var pCoreTemps: [Double] = []

        // Use cached keys if available, otherwise scan and cache
        let keysToRead: [(key: String, name: String, category: TemperatureCategory)]
        if let cached = HardwareMonitor.validTempKeysCache {
            keysToRead = cached
        } else {
            // First run: scan all keys and cache only valid ones
            var validKeys: [(key: String, name: String, category: TemperatureCategory)] = []
            for item in knownTempKeys {
                if readKeyData(item.key) != nil {
                    validKeys.append(item)
                }
            }
            HardwareMonitor.validTempKeysCache = validKeys
            keysToRead = validKeys
            debugLog("Cached \(validKeys.count) valid temperature keys")
        }

        for item in keysToRead {
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

    func readTempSensor(key: String, name: String, category: TemperatureCategory) -> TemperatureSensor? {
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
}
