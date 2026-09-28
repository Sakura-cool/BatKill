//  FanController.swift
//  BatKill
//
//  Extension on HardwareMonitor providing fan reading, fan speed/mode control,
//  and administrator authorization for privileged SMC writes. Fan speed
//  writes require elevated permissions because macOS restricts direct SMC
//  access to root for fan control keys.
//
//  Two access paths:
//  1. Direct SMC writes (no admin) -- works for reading, may fail on writes
//  2. Admin-authorized writes -- uses AuthorizationServices to run the app's
//     own executable with privileges via AuthorizationExecuteWithPrivileges

import Foundation
import Security

extension HardwareMonitor {

    // MARK: - Fan Control (Direct SMC)

    /// Sets a fan to automatic (system-controlled) or manual mode.
    /// Writes to the `F{index}Md` SMC key: 0 = auto, 1 = manual.
    /// Refreshes all hardware data after the write.
    ///
    /// - Parameters:
    ///   - fanIndex: Zero-based fan index.
    ///   - auto: `true` for automatic mode, `false` for manual mode.
    /// - Returns: `true` if the SMC write succeeded.
    func setFanMode(fanIndex: Int, auto: Bool) -> Bool {
        let ctx = LogContext(name: "setFanMode")
        ctx.log("设置风扇 \(fanIndex) 模式: \(auto ? "自动" : "手动")")
        let key = String(format: "F%dMd", fanIndex)
        var value: UInt8 = auto ? 0 : 1
        let ok = writeBytes(key: key, bytes: &value, length: 1)
        lastFanWriteOK = ok
        ctx.complete(success: ok)
        refresh()
        return ok
    }

    func setFanSpeed(fanIndex: Int, speed: Double) -> Bool {
        let ctx = LogContext(name: "setFanSpeed")
        ctx.log("设置风扇 \(fanIndex) 转速: \(Int(speed)) RPM")
        let ok = writeFanTarget(fanIndex: fanIndex, speed: speed)
        lastFanWriteOK = ok
        ctx.complete(success: ok)
        refresh()
        return ok
    }

    /// Writes a target fan speed to the `F{index}Tg` SMC key, auto-detecting
    /// the correct encoding format from the key's metadata:
    ///
    /// - `fpe2`: UInt16 with speed * 4 (standard fan target encoding)
    /// - `flt`:  Float32 (direct floating-point value)
    /// - Default: UInt16 (raw speed value)
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

    // MARK: - Admin Write Channel (sudo)

    func runWithAdmin(args: [String], completion: @escaping (Bool) -> Void) {
        // The sudo channel is stable (no per-call dialog); just verify the
        // tool + rule are installed. A transient failure is retried on the
        // next timer tick rather than latched (CHANGE-019).
        guard FanInstallManager.isSudoReady() else {
            logger("FanController: sudo 通道未就绪（未安装 batkill-fan 或 sudoers 规则），写入被拒绝")
            completion(false)
            return
        }

        // Serialize all sudo invocations on one queue: only one privileged
        // write in flight at a time (CHANGE-016).
        HardwareMonitor.adminAuthQueue.async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            p.arguments = ["-n", FanInstallManager.cliPath] + args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                let ok = proc.terminationStatus == 0
                if !ok {
                    logger("FanController: sudo batkill-fan 失败（exit \(proc.terminationStatus)）")
                }
                self?.refresh()
                DispatchQueue.main.async { completion(ok) }
            }
            do {
                try p.run()
            } catch {
                logger("FanController: 启动 sudo 失败 \(error.localizedDescription)")
                self?.refresh()
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    /// Sets a fan to automatic or manual mode using admin privileges.
    /// Passes `--set-fan-mode {index} {mode}` to the elevated binary.
    ///
    /// v0.1.6 FIX-002：写入前校验风扇索引（白名单 + 实际风扇数），非法请求直接拒绝。
    func setFanModeWithAdmin(fanIndex: Int, auto: Bool, completion: @escaping (Bool) -> Void) {
        let fans = readFans()
        guard fans.contains(where: { $0.index == fanIndex }) else {
            logger("FanController: 非法风扇索引 \(fanIndex)（检测到 \(fans.count) 个风扇），写入被拒绝")
            completion(false)
            return
        }
        // All writes go through the sudo channel (CHANGE-019).
        let mode = auto ? 0 : 1
        runWithAdmin(args: ["--set-fan-mode", "\(fanIndex)", "\(mode)"], completion: completion)
    }

    /// Sets a fan's target speed using admin privileges.
    /// Passes `--set-fan {index} {speed}` to the elevated binary.
    func setFanSpeedWithAdmin(fanIndex: Int, speed: Double, completion: @escaping (Bool) -> Void) {
        guard speed.isFinite, speed >= 0 else {
            logger("FanController: 非法转速请求 \(speed)，写入被拒绝")
            completion(false)
            return
        }
        let fans = readFans()
        guard let fan = fans.first(where: { $0.index == fanIndex }) else {
            logger("FanController: 非法风扇索引 \(fanIndex)（检测到 \(fans.count) 个风扇），写入被拒绝")
            completion(false)
            return
        }
        let target = clampFanSpeed(speed, min: fan.minSpeed, max: fan.maxSpeed)
        if target != speed {
            logger("FanController: 转速 \(Int(speed)) 超出范围 "
                + "[\(Int(fan.minSpeed)), \(Int(fan.maxSpeed))]，已收敛为 \(Int(target))")
        }
        // All writes go through the sudo channel (CHANGE-019) — direct SMC
        // writes need root and the old AEWP path is dead on current macOS.
        runWithAdmin(args: ["--set-fan", "\(fanIndex)", "\(Int(target))"], completion: completion)
    }

    // MARK: - Fan Reading

    /// Reads all fan information from the SMC. Queries the `FNum` key
    /// for the total fan count, then reads each fan's name, min/max/current
    /// speeds, and auto/manual mode.
    ///
    /// - Returns: Array of `FanInfo` structs, one per detected fan.
    func readFans() -> [FanInfo] {
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

    /// Reads a single fan speed value from an SMC key, auto-detecting
    /// the encoding format: Float32 (`flt`), fixed-point /4 (`fds`/`fpe2`),
    /// or raw UInt16.
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
            let raw = UInt16(data.bytes[0]) << 8 | UInt16(data.bytes[1])
            return Double(raw) / 4.0
        } else {
            let raw = Int(data.bytes[0]) << 8 | Int(data.bytes[1])
            return Double(raw)
        }
    }

    /// Reads a null-terminated UTF-8 string from an SMC key (used for
    /// fan names). Strips trailing null bytes before decoding.
    private func readFanString(key: String) -> String? {
        guard let bytes = readBytes(key: key) else { return nil }
        let trimmed = bytes.filter { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8)
    }
}

/// 将请求转速收敛到风扇的 [min, max] 区间，防止越界写入 SMC
/// （v0.1.6 FIX-002：提权写入前的转速范围收敛）。
/// 抽成纯函数以便单测直接覆盖收敛边界（CHANGE-019 测试补全）。
func clampFanSpeed(_ speed: Double, min minSpeed: Double, max maxSpeed: Double) -> Double {
    min(max(speed, minSpeed), maxSpeed)
}
