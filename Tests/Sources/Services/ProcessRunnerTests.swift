//  ProcessRunnerTests.swift
//  BatKill Tests
//
//  Tests for the v0.1.6 security fixes:
//    - 外部标识白名单（FIX-001 / BUG-001）
//    - 进程执行不经 shell：参数中的 shell 元字符原样传递（FIX-001 / BUG-004）
//    - 日志路径改为用户私有目录（FIX-003 / BUG-003）

import Foundation

final class ProcessRunnerTests: TestCase {
    let name = "ProcessRunnerTests"

    func setUp() {}
    func tearDown() {}

    func run() {
        // MARK: 外部标识白名单

        runTest("白名单接受正常服务名与 label") {
            XCTAssertTrue(ProcessRunner.isValidExternalIdentifier("nginx"), "nginx 应通过")
            XCTAssertTrue(ProcessRunner.isValidExternalIdentifier("homebrew.mxcl.colima"), "brew 服务名应通过")
            XCTAssertTrue(ProcessRunner.isValidExternalIdentifier("com.docker.vmnetd"), "launchd label 应通过")
            XCTAssertTrue(ProcessRunner.isValidExternalIdentifier("my_service-2@x"), "下划线/短横/at 应通过")
        }

        runTest("白名单拒绝 shell 元字符与路径穿越") {
            let rejected = ["", " ", "a b", "a;b", "a&&b", "a|b", "a$(whoami)", "a`id`",
                            "a\"b", "a'b", "a\nb", "../../etc/passwd", "/bin/sh",
                            "a>b", "a<b", "a&b", String(repeating: "a", count: 65)]
            for value in rejected {
                XCTAssertFalse(ProcessRunner.isValidExternalIdentifier(value),
                               "应拒绝非法标识：\(value.debugDescription)")
            }
        }

        runTest("resolveExecutable 对非法名字返回 nil") {
            XCTAssertNil(ProcessRunner.resolveExecutable(named: "sh;rm -rf /"), "非法名字不得解析")
            XCTAssertNil(ProcessRunner.resolveExecutable(named: "../bin/sh"), "路径穿越不得解析")
        }

        runTest("resolveExecutable 能解析常见系统二进制") {
            XCTAssertNotNil(ProcessRunner.resolveExecutable(named: "launchctl"), "launchctl 应可解析")
            XCTAssertNotNil(ProcessRunner.resolveExecutable(named: "echo"), "echo 应可解析")
        }

        // MARK: 不经 shell 执行（BUG-001 / BUG-004 回归）

        runTest("参数中的 shell 元字符原样传递（不经 shell）") {
            let payload = "a; whoami $(id) `uname` && rm -rf /tmp/should-not-run"
            guard let result = try? ProcessRunner.run(executable: "/bin/echo", arguments: ["-n", payload]) else {
                XCTAssertTrue(false, "echo 执行失败")
                return
            }
            XCTAssertEqual(result.output, payload, "shell 元字符必须原样作为参数传递，不得被解释")
            XCTAssertTrue(result.succeeded, "echo 应成功退出")
        }

        runTest("非可执行文件被拒绝") {
            var rejected = false
            do {
                _ = try ProcessRunner.run(executable: "/etc/hosts")
            } catch {
                rejected = true
            }
            XCTAssertTrue(rejected, "非可执行文件应抛错而不是尝试执行")
        }

        runTest("run 返回退出码与输出") {
            guard let result = try? ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "exit 3"]) else {
                XCTAssertTrue(false, "/bin/sh 执行失败")
                return
            }
            XCTAssertEqual(result.status, 3, "退出码应透传")
            XCTAssertFalse(result.succeeded, "非 0 退出码不算成功")
        }

        // MARK: 日志路径（FIX-003 / BUG-003）

        runTest("日志路径位于用户私有目录或临时目录，不再是 /tmp 固定路径") {
            let path = LogFile.path
            XCTAssertFalse(path.hasPrefix("/tmp/batkill.log"), "不得再使用 /tmp/batkill.log")
            XCTAssertTrue(path.hasSuffix("batkill.log"), "日志文件名应为 batkill.log")
            let inLibLogs = path.contains("/Library/Logs/BatKill/")
            let inTemp = path.hasPrefix(FileManager.default.temporaryDirectory.path)
            XCTAssertTrue(inLibLogs || inTemp, "日志应写入 ~/Library/Logs/BatKill/ 或临时目录，实际：\(path)")
        }

        runTest("日志目录存在且权限为 0700") {
            let directory = LogFile.url.deletingLastPathComponent()
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertNotNil(attributes, "日志目录应存在")
            if let permissions = attributes?[.posixPermissions] as? NSNumber {
                XCTAssertEqual(permissions.intValue, 0o700, "日志目录权限应为 0700")
            }
        }

        runTest("日志可写入并可读回") {
            let marker = "v0.1.6-test-\(UUID().uuidString.prefix(8))"
            logger(marker)
            LogQueue.shared.flushSync()
            let content = try? String(contentsOfFile: LogFile.path, encoding: .utf8)
            XCTAssertNotNil(content, "日志文件应可读取")
            XCTAssertTrue(content?.contains(marker) ?? false, "写入的日志应能在新路径读回")
        }
    }
}
