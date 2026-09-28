//  TemperatureReadingTests.swift
//  BatKill Tests
//
//  Tests for SMC temperature decoding (CHANGE-020 test coverage).

import Foundation

final class TemperatureReadingTests: TestCase {
    let name = "TemperatureReadingTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("sp78 类型解码（主数据格式）") {
            // 70.0°C = 0x46 * 256 + 0x00 → bytes [0x46, 0x00]
            let temp = decodeSMCTemperature(bytes: [0x46, 0x00], dataType: HardwareMonitor.sp78Type)
            XCTAssertEqualWithAccuracy(temp, 70.0, accuracy: 0.01, "sp78: 0x4600 = 70.0")
        }

        runTest("sp78 负温度解码") {
            // -1.0°C = Int16(-256) >> ... sp78: 0xFF00 = -1.0
            let temp = decodeSMCTemperature(bytes: [0xFF, 0x00], dataType: HardwareMonitor.sp78Type)
            XCTAssertEqualWithAccuracy(temp, -1.0, accuracy: 0.01, "sp78: 0xFF00 = -1.0")
        }

        runTest("fds 类型解码（/4 缩放）") {
            // 5000 RPM-ish sensor value: 0x1388 / 4 = 1250.0
            let temp = decodeSMCTemperature(bytes: [0x13, 0x88], dataType: HardwareMonitor.fdsType)
            XCTAssertEqualWithAccuracy(temp, 1250.0, accuracy: 0.01, "fds: 0x1388 / 4 = 1250.0")
        }

        runTest("fpe2 类型解码（/64 缩放）") {
            // 0x0A00 / 64 = 40.0
            let temp = decodeSMCTemperature(bytes: [0x0A, 0x00], dataType: HardwareMonitor.fpe2Type)
            XCTAssertEqualWithAccuracy(temp, 40.0, accuracy: 0.01, "fpe2: 0x0A00 / 64 = 40.0")
        }

        runTest("flt 类型解码（Float32）") {
            var bytes = [UInt8](repeating: 0, count: 4)
            let value: Float32 = 36.5
            withUnsafeBytes(of: value) { bytes.replaceSubrange(0..<4, with: $0) }
            let temp = decodeSMCTemperature(bytes: bytes, dataType: HardwareMonitor.fltType)
            XCTAssertEqualWithAccuracy(temp, 36.5, accuracy: 0.01, "flt: Float32 直读")
        }

        runTest("默认 raw/256 解码（未知类型）") {
            // 0x1000 / 256 = 16.0
            let temp = decodeSMCTemperature(bytes: [0x10, 0x00], dataType: 0xDEADBEEF)
            XCTAssertEqualWithAccuracy(temp, 16.0, accuracy: 0.01, "默认 /256")
        }

        runTest("短字节返回 0（防御）") {
            let temp = decodeSMCTemperature(bytes: [0x46], dataType: HardwareMonitor.sp78Type)
            XCTAssertEqual(temp, 0, "不足 2 字节返回 0")
        }
    }
}
