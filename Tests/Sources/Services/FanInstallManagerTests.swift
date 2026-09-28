//  FanInstallManagerTests.swift
//  BatKill Tests
//
//  Tests for the CHANGE-019 sudoers NOPASSWD fan-write channel:
//  path/rule constants and install-state detection.

import Foundation

final class FanInstallManagerTests: TestCase {
    let name = "FanInstallManagerTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        runTest("sudoers 规则文件名不含点号") {
            XCTAssertFalse(
                FanInstallManager.sudoersName.contains("."),
                "sudo 会忽略 /etc/sudoers.d/ 中带点号的文件（visudo 约定），规则名必须是 batkill-fan"
            )
            XCTAssertEqual(FanInstallManager.sudoersName, "batkill-fan")
        }

        runTest("CLI 与规则路径指向固定的 root 属主位置") {
            XCTAssertEqual(FanInstallManager.cliPath, "/usr/local/BatKill/batkill-fan")
            XCTAssertEqual(FanInstallManager.sudoersPath, "/etc/sudoers.d/batkill-fan")
            XCTAssertTrue(
                FanInstallManager.cliPath.hasPrefix("/usr/local/BatKill/"),
                "CLI 必须装在 root 属主目录而非 PATH，防止被替换"
            )
        }

        runTest("isInstalled() 与文件系统状态一致") {
            let cliExists = FileManager.default.fileExists(atPath: FanInstallManager.cliPath)
            let ruleExists = FileManager.default.fileExists(atPath: FanInstallManager.sudoersPath)
            XCTAssertEqual(
                FanInstallManager.isInstalled(),
                cliExists && ruleExists,
                "isInstalled() 必须等于 CLI 与 sudoers 规则同时存在"
            )
        }

        runTest("isSudoReady() 与安装状态一致（sudo -n -l 免密可达）") {
            let installed = FanInstallManager.isInstalled()
            let ready = FanInstallManager.isSudoReady()
            if installed {
                XCTAssertTrue(ready, "已安装 sudo 通道时 sudo -n -l 应返回 0（本机实际安装验证）")
            } else {
                XCTAssertFalse(ready, "未安装时 sudo -n -l 不得免密通过")
            }
        }

        runTest("fanControlEnabled 初始值与安装状态同步，refresh 重新拉取") {
            let monitor = HardwareMonitor()
            XCTAssertEqual(
                monitor.fanControlEnabled,
                FanInstallManager.isInstalled(),
                "UI 门控初始值应等于安装状态"
            )
            monitor.refreshFanControlEnabled()
            XCTAssertEqual(
                monitor.fanControlEnabled,
                FanInstallManager.isInstalled(),
                "refreshFanControlEnabled() 应重新同步安装状态"
            )
        }

        runTest("sudoers 规则：三行 NOPASSWD，命令与参数限定正确") {
            let rule = FanInstallManager.sudoersRule(for: "tester")
            XCTAssertTrue(rule.hasSuffix("\n"), "规则必须以换行结尾（sudoers 逐行解析）")
            XCTAssertFalse(rule.contains("^") || rule.contains("$"),
                           "不得使用 ERE 锚点（macOS sudo 不支持 ERE 参数匹配，^[0-9]+$ 永不生效）")

            let lines = rule.components(separatedBy: "\n").filter { !$0.isEmpty }
            XCTAssertEqual(lines.count, 3, "应恰好三行：--set-fan、--set-fan-mode、--verify-fan")

            let setFanLine = lines[0]
            XCTAssertTrue(
                setFanLine.hasPrefix("tester ALL=(root) NOPASSWD: \(FanInstallManager.cliPath) --set-fan "),
                "set-fan 行必须以 用户/NOPASSWD/CLI 路径 开头"
            )
            XCTAssertTrue(
                setFanLine.hasSuffix("--set-fan [0-9]* [0-9]*"),
                "set-fan 参数必须是 fnmatch 通配符 [0-9]* [0-9]*"
            )

            let setModeLine = lines[1]
            XCTAssertTrue(
                setModeLine.hasPrefix("tester ALL=(root) NOPASSWD: \(FanInstallManager.cliPath) --set-fan-mode "),
                "set-fan-mode 行必须以 用户/NOPASSWD/CLI 路径 开头"
            )
            XCTAssertTrue(
                setModeLine.hasSuffix("--set-fan-mode [0-9]* [01]"),
                "set-fan-mode 参数必须是 [0-9]* [01]（模式仅 0/1）"
            )

            let verifyLine = lines[2]
            XCTAssertTrue(
                verifyLine.hasPrefix("tester ALL=(root) NOPASSWD: \(FanInstallManager.cliPath) --verify-fan "),
                "verify-fan 行必须以 用户/NOPASSWD/CLI 路径 开头"
            )
            XCTAssertTrue(
                verifyLine.hasSuffix("--verify-fan [0-9]* [0-9]*"),
                "verify-fan 参数必须是 fnmatch 通配符 [0-9]* [0-9]*"
            )
        }

        runTest("sudoers 规则：仅放行指定用户与指定命令，无通配") {
            let rule = FanInstallManager.sudoersRule(for: "u_ser-1")
            let lines = rule.components(separatedBy: "\n").filter { !$0.isEmpty }
            XCTAssertEqual(lines.count, 3)
            XCTAssertTrue(
                lines.allSatisfy { $0.hasPrefix("u_ser-1 ALL=(root) NOPASSWD:") },
                "每行必须精确放行指定用户"
            )
            XCTAssertFalse(rule.contains("ALL=(ALL)"), "不得放行任意用户")
            XCTAssertFalse(rule.contains("NOPASSWD: ALL"), "不得放行任意命令")
        }
    }
}
