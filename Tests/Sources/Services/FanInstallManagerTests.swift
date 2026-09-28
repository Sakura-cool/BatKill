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
    }
}
