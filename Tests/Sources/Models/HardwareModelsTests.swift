//  HardwareModelsTests.swift
//  BatKill Tests
//
//  Unit tests for hardware-related models.
//  Tests TemperatureCategory, TemperatureGroup, and data structures.

import Foundation

final class HardwareModelsTests: TestCase {
    let name = "HardwareModelsTests"
    
    func setUp() {}
    func tearDown() {}
    
    func run() {
        testTemperatureCategoryRawValues()
        testTemperatureCategoryCaseIterable()
        testTemperatureCategorySystemImage()
        testTemperatureCategoryLocalizedName()
        testTemperatureCategoryID()
        testTemperatureGroupAverage()
        testTemperatureGroupAverageEmpty()
        testTemperatureSensorInitialization()
        testFanInfoInitialization()
        testSMCKeyInfoDataDefaults()
        testSMCParamStructDefaults()
        testSMCCommandConstants()
    }
    
    // MARK: - TemperatureCategory Tests
    
    private func testTemperatureCategoryRawValues() {
        runTest("TemperatureCategory raw values") {
            XCTAssertEqual(TemperatureCategory.cpu.rawValue, "CPU")
            XCTAssertEqual(TemperatureCategory.gpu.rawValue, "GPU")
            XCTAssertEqual(TemperatureCategory.memory.rawValue, "Memory")
            XCTAssertEqual(TemperatureCategory.battery.rawValue, "Battery")
            XCTAssertEqual(TemperatureCategory.storage.rawValue, "Storage")
            XCTAssertEqual(TemperatureCategory.ambient.rawValue, "Ambient")
            XCTAssertEqual(TemperatureCategory.other.rawValue, "Other")
        }
    }
    
    private func testTemperatureCategoryCaseIterable() {
        runTest("TemperatureCategory case iterable") {
            let allCases = TemperatureCategory.allCases
            XCTAssertEqual(allCases.count, 7, "Should have 7 categories")
            XCTAssertTrue(allCases.contains(.cpu))
            XCTAssertTrue(allCases.contains(.gpu))
            XCTAssertTrue(allCases.contains(.memory))
            XCTAssertTrue(allCases.contains(.battery))
            XCTAssertTrue(allCases.contains(.storage))
            XCTAssertTrue(allCases.contains(.ambient))
            XCTAssertTrue(allCases.contains(.other))
        }
    }
    
    private func testTemperatureCategorySystemImage() {
        runTest("TemperatureCategory system images") {
            XCTAssertEqual(TemperatureCategory.cpu.systemImage, "cpu")
            XCTAssertEqual(TemperatureCategory.gpu.systemImage, "display")
            XCTAssertEqual(TemperatureCategory.memory.systemImage, "memorychip")
            XCTAssertEqual(TemperatureCategory.battery.systemImage, "battery.100")
            XCTAssertEqual(TemperatureCategory.storage.systemImage, "internaldrive")
            XCTAssertEqual(TemperatureCategory.ambient.systemImage, "thermometer.medium")
            XCTAssertEqual(TemperatureCategory.other.systemImage, "gearshape")
        }
    }
    
    private func testTemperatureCategoryLocalizedName() {
        runTest("TemperatureCategory localized names") {
            XCTAssertEqual(TemperatureCategory.cpu.localizedName.en, "CPU")
            XCTAssertEqual(TemperatureCategory.cpu.localizedName.zh, "处理器")
            
            XCTAssertEqual(TemperatureCategory.gpu.localizedName.en, "GPU")
            XCTAssertEqual(TemperatureCategory.gpu.localizedName.zh, "显卡")
            
            XCTAssertEqual(TemperatureCategory.memory.localizedName.en, "Memory")
            XCTAssertEqual(TemperatureCategory.memory.localizedName.zh, "内存")
            
            XCTAssertEqual(TemperatureCategory.battery.localizedName.en, "Battery")
            XCTAssertEqual(TemperatureCategory.battery.localizedName.zh, "电池")
            
            XCTAssertEqual(TemperatureCategory.storage.localizedName.en, "Storage")
            XCTAssertEqual(TemperatureCategory.storage.localizedName.zh, "存储")
            
            XCTAssertEqual(TemperatureCategory.ambient.localizedName.en, "Ambient")
            XCTAssertEqual(TemperatureCategory.ambient.localizedName.zh, "环境")
            
            XCTAssertEqual(TemperatureCategory.other.localizedName.en, "Other")
            XCTAssertEqual(TemperatureCategory.other.localizedName.zh, "其他")
        }
    }
    
    private func testTemperatureCategoryID() {
        runTest("TemperatureCategory id matches raw value") {
            XCTAssertEqual(TemperatureCategory.cpu.id, "CPU")
            XCTAssertEqual(TemperatureCategory.gpu.id, "GPU")
            XCTAssertEqual(TemperatureCategory.memory.id, "Memory")
            XCTAssertEqual(TemperatureCategory.battery.id, "Battery")
            XCTAssertEqual(TemperatureCategory.storage.id, "Storage")
            XCTAssertEqual(TemperatureCategory.ambient.id, "Ambient")
            XCTAssertEqual(TemperatureCategory.other.id, "Other")
        }
    }
    
    // MARK: - TemperatureGroup Tests
    
    private func testTemperatureGroupAverage() {
        runTest("TemperatureGroup average calculation") {
            let sensors = [
                TemperatureSensor(key: "Tp01", name: "Core 1", temperature: 65.0, category: .cpu),
                TemperatureSensor(key: "Tp02", name: "Core 2", temperature: 70.0, category: .cpu),
                TemperatureSensor(key: "Tp03", name: "Core 3", temperature: 75.0, category: .cpu)
            ]
            
            let group = TemperatureGroup(category: .cpu, sensors: sensors)
            
            XCTAssertEqualWithAccuracy(group.average, 70.0, accuracy: 0.01,
                                       "Average of 65, 70, 75 should be 70")
        }
    }
    
    private func testTemperatureGroupAverageEmpty() {
        runTest("TemperatureGroup average with no sensors") {
            let group = TemperatureGroup(category: .cpu, sensors: [])
            
            XCTAssertEqual(group.average, 0, "Average of empty group should be 0")
        }
    }
    
    // MARK: - TemperatureSensor Tests
    
    private func testTemperatureSensorInitialization() {
        runTest("TemperatureSensor initialization") {
            let sensor = TemperatureSensor(
                key: "TCPU",
                name: "CPU Package",
                temperature: 72.5,
                category: .cpu
            )
            
            XCTAssertNotNil(sensor.id, "Should have auto-generated UUID")
            XCTAssertEqual(sensor.key, "TCPU")
            XCTAssertEqual(sensor.name, "CPU Package")
            XCTAssertEqual(sensor.temperature, 72.5)
            XCTAssertEqual(sensor.category, .cpu)
        }
    }
    
    // MARK: - FanInfo Tests
    
    private func testFanInfoInitialization() {
        runTest("FanInfo initialization") {
            let fan = FanInfo(
                index: 0,
                name: "Left",
                minSpeed: 2000,
                maxSpeed: 6200,
                currentSpeed: 3500,
                isAutoMode: true
            )
            
            XCTAssertNotNil(fan.id, "Should have auto-generated UUID")
            XCTAssertEqual(fan.index, 0)
            XCTAssertEqual(fan.name, "Left")
            XCTAssertEqual(fan.minSpeed, 2000)
            XCTAssertEqual(fan.maxSpeed, 6200)
            XCTAssertEqual(fan.currentSpeed, 3500)
            XCTAssertTrue(fan.isAutoMode)
        }
    }
    
    // MARK: - SMC Data Structure Tests
    
    private func testSMCKeyInfoDataDefaults() {
        runTest("SMCKeyInfoData default values") {
            let info = SMCKeyInfoData()
            
            XCTAssertEqual(info.dataSize, 0)
            XCTAssertEqual(info.dataType, 0)
            XCTAssertEqual(info.dataAttributes, 0)
        }
    }
    
    private func testSMCParamStructDefaults() {
        runTest("SMCParamStruct default values") {
            let param = SMCParamStruct()
            
            XCTAssertEqual(param.key, 0)
            XCTAssertEqual(param.data8, 0)
            XCTAssertEqual(param.result, 0)
            XCTAssertEqual(param.status, 0)
        }
    }
    
    private func testSMCCommandConstants() {
        runTest("SMC command constants") {
            XCTAssertEqual(kSMCReadKey, 5)
            XCTAssertEqual(kSMCWriteKey, 6)
            XCTAssertEqual(kSMCGetKeyInfo, 9)
        }
    }
}
