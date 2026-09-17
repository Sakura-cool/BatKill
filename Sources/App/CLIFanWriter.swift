//  CLIFanWriter.swift
//  BatKill
//
//  Handles command-line arguments for fan-speed writes.
//
//  When the user authorizes admin privileges for fan control, the app
//  re-launches itself as a child process with elevated rights (via
//  AuthorizationExecuteWithPrivileges). The re-launched process passes
//  `--set-fan <index> <speed>` or `--set-fan-mode <index> 0|1` on the
//  command line. This function parses those arguments, performs the
//  SMC write, and exits with status 0 (success) or 1 (failure).
//
//  Usage:
//    BatKill --set-fan <fanIndex> <speedRPM>
//    BatKill --set-fan-mode <fanIndex> <0|1>
//      0 = automatic, 1 = manual
//
//  This function is called from AppDelegate.applicationDidFinishLaunching()
//  before any UI setup. If it returns true, the app exits immediately
//  after the write.

import Foundation

/// Parses `--set-fan` / `--set-fan-mode` CLI arguments and writes fan
/// configuration directly via SMC. Returns `true` if the app should
/// exit after this call (CLI mode), or `false` to continue normal launch.
@discardableResult
func handleCLIArgs() -> Bool {
    let args = CommandLine.arguments
    guard args.count >= 2 else { return false }

    // --set-fan <fanIndex> <speedRPM>
    // Sets the fan to manual mode at the given RPM, then exits.
    // v0.1.6 FIX-002：提权入口收口——参数做白名单与范围校验，非法请求拒绝执行（exit 1）
    if args[1] == "--set-fan", args.count == 4 {
        guard let fanIndex = Int(args[2]), fanIndex >= 0, maxFanIndex >= fanIndex else {
            logger("CLIFanWriter: 非法风扇索引参数 \(args[2])，提权写入被拒绝")
            exit(1)
        }
        guard let speed = Double(args[3]), speed.isFinite, speed >= 0, speed <= maxFanSpeedRPM else {
            logger("CLIFanWriter: 非法转速参数 \(args[3])（允许 0...\(Int(maxFanSpeedRPM))），提权写入被拒绝")
            exit(1)
        }
        let monitor = HardwareMonitor()
        monitor.setFanMode(fanIndex: fanIndex, auto: false)
        _ = monitor.setFanSpeed(fanIndex: fanIndex, speed: speed)
        exit(monitor.lastFanWriteOK ? 0 : 1)
    }

    // --set-fan-mode <fanIndex> <0|1>
    // 0 = automatic, 1 = manual. Then exits.
    if args[1] == "--set-fan-mode", args.count == 4 {
        guard let fanIndex = Int(args[2]), fanIndex >= 0, maxFanIndex >= fanIndex else {
            logger("CLIFanWriter: 非法风扇索引参数 \(args[2])，提权写入被拒绝")
            exit(1)
        }
        guard let mode = Int(args[3]), mode == 0 || mode == 1 else {
            logger("CLIFanWriter: 非法模式参数 \(args[3])（允许 0/1），提权写入被拒绝")
            exit(1)
        }
        let monitor = HardwareMonitor()
        _ = monitor.setFanMode(fanIndex: fanIndex, auto: mode == 0)
        exit(monitor.lastFanWriteOK ? 0 : 1)
    }

    return false
}

// MARK: - CLI 参数白名单（v0.1.6 FIX-002）

/// 提权入口允许的最大风扇索引（SMC 实际风扇数远小于此值，仅作上界防护）。
private let maxFanIndex = 15

/// 提权入口允许的最大转速（RPM）；真实上界由各风扇的 `F{i}Mx` 决定。
private let maxFanSpeedRPM: Double = 20000
