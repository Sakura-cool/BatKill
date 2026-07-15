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

    // MARK: - Admin Authorization

    /// Requests one-time administrator authorization via the macOS
    /// AuthorizationServices framework.
    ///
    /// Authorization lifecycle (three states, single-instance):
    ///   1. **Authorized** (`authRef != nil`) → immediately returns `true`
    ///   2. **Denied** (`authDenied == true`) → returns `false` without dialog
    ///   3. **In flight** (`authInProgress == true`) → returns `false` without dialog
    ///
    /// The denied state is reset by `HardwareMonitor.resetAuthDenied()` which
    /// callers MUST invoke before explicit user-initiated retries (button taps).
    /// Automatic/derived callers must NOT reset — they should respect the denial.
    ///
    /// - Returns: `true` if authorization was granted.
    func requestAdminAuth() -> Bool {
        let ctx = LogContext(name: "requestAdminAuth")

        // ── 1. Already authorized → reuse ──
        if HardwareMonitor.authRef != nil {
            isAdminAuthorized = true
            HardwareMonitor.authDenied = false
            ctx.complete(success: true, extra: "复用现有授权")
            return true
        }

        // ── 2. Previously denied → honour user's choice, no dialog ──
        guard !HardwareMonitor.authDenied else {
            ctx.log("用户此前拒绝了授权，跳过弹窗")
            return false
        }

        // ── 3. Already in flight → single-instance guard ──
        guard !HardwareMonitor.authInProgress else {
            ctx.log("授权弹窗已存在，跳过")
            return false
        }

        // ── 4. Show the system auth dialog ──
        HardwareMonitor.authInProgress = true
        defer {
            // The synchronous call below blocks until user interacts,
            // so inProgress is always reset immediately after, but the
            // guard above prevents concurrent entry from other callers.
            HardwareMonitor.authInProgress = false
        }

        var ref: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess,
              let ref = ref else {
            ctx.fail("创建授权引用失败")
            HardwareMonitor.authDenied = true
            return false
        }

        let rightName = kAuthorizationRightExecute
        let ok = rightName.withCString { cName in
            var item = AuthorizationItem(name: cName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { itemPtr in
                var rights = AuthorizationRights(count: 1, items: itemPtr)
                let flags: AuthorizationFlags = [.preAuthorize, .extendRights, .interactionAllowed]
                return AuthorizationCopyRights(ref, &rights, nil, flags, nil) == errAuthorizationSuccess
            }
        }

        if ok {
            HardwareMonitor.authRef = ref
            isAdminAuthorized = true
            HardwareMonitor.authDenied = false
            ctx.complete(success: true)
        } else {
            AuthorizationFree(ref, [.destroyRights])
            HardwareMonitor.authDenied = true
            ctx.fail("授权被拒绝或取消")
        }
        return ok
    }

    /// Executes the app's own binary with elevated privileges, passing
    /// the given command-line arguments. Uses `AuthorizationExecuteWithPrivileges`
    /// (deprecated API loaded via `dlsym` since it's not in Swift headers).
    ///
    /// Runs asynchronously on a background queue; calls `completion` on main
    /// thread after the privileged process exits and a data refresh completes.
    ///
    /// - Parameters:
    ///   - args: Command-line arguments to pass to the binary.
    ///   - completion: Called on the main thread with `true` when done.
    func runWithAdmin(args: [String], completion: @escaping (Bool) -> Void) {
        guard let authRef = HardwareMonitor.authRef,
              let execPath = Bundle.main.executablePath else {
            completion(false)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Convert Swift strings to C strings for the auth API
            var cArgs = args.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }

            // Load the deprecated AuthorizationExecuteWithPrivileges at runtime
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

            // refresh() handles its own background/main-thread scheduling
            self?.refresh()
            DispatchQueue.main.async {
                completion(true)
            }
        }
    }

    /// Sets a fan to automatic or manual mode using admin privileges.
    /// Passes `--set-fan-mode {index} {mode}` to the elevated binary.
    func setFanModeWithAdmin(fanIndex: Int, auto: Bool, completion: @escaping (Bool) -> Void) {
        let mode = auto ? 0 : 1
        runWithAdmin(args: ["--set-fan-mode", "\(fanIndex)", "\(mode)"], completion: completion)
    }

    /// Sets a fan's target speed using admin privileges.
    /// Passes `--set-fan {index} {speed}` to the elevated binary.
    func setFanSpeedWithAdmin(fanIndex: Int, speed: Double, completion: @escaping (Bool) -> Void) {
        runWithAdmin(args: ["--set-fan", "\(fanIndex)", "\(Int(speed))"], completion: completion)
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
            let raw = Int16(data.bytes[0]) << 8 | Int16(data.bytes[1])
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
