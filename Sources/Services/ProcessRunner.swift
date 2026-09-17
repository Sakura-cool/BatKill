//  ProcessRunner.swift
//  BatKill
//
//  进程执行与外部标识校验的统一入口（v0.1.6 安全修复 FIX-001 / FIX-004）。
//
//  背景：0.1.5 及以前多处把插值拼进 shell 命令文本
//  （`/bin/bash -c "\(value) start"`），外部数据（服务名、路径）一旦含
//  `"`、`;`、`$()`、反引号或空格，就会被 shell 解释为额外命令或重定向。
//
//  本文件提供：
//    1. `isValidExternalIdentifier(_:)`  外部标识白名单（服务名 / launchd label）
//    2. `run(executable:arguments:environment:)`  以「具体二进制 + 参数数组」执行，不经过 shell
//    3. `runDetached(...)`  启动后立即返回（用于交给后台的自更新脚本）
//    4. `brewPath()` / `resolveExecutable(named:)`  不依赖 shell 的可执行文件探测
//
//  规则（v0.1.6 起）：工程内不得新增 `/bin/bash -c`、`/bin/zsh -c` 形式的动态命令文本；
//  必须经 shell 时，命令文本只能是常量，变量一律通过参数传入。

import Foundation

/// 进程执行与校验工具（无状态枚举，全部为静态方法）。
enum ProcessRunner {

    // MARK: - Validation

    /// 外部标识白名单：服务名、launchd label、可执行文件名。
    ///
    /// 仅允许字母、数字、`.`、`_`、`@`、`-`，长度 1...64；
    /// 空格、引号、`;`、`$`、反引号、`/`、换行等一律拒绝（返回 `false`）。
    static func isValidExternalIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.range(of: #"^[A-Za-z0-9._@-]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Execution

    /// 执行结果。
    struct Result {
        /// 进程退出码（0 = 成功）。
        let status: Int32
        /// 合并后的 stdout + stderr。
        let output: String
        /// 是否成功。
        var succeeded: Bool { status == 0 }
    }

    /// 执行期错误。
    enum RunnerError: Error, CustomStringConvertible {
        /// 目标不是可执行文件。
        case invalidExecutable(String)
        /// 目标不是外部标识白名单允许的形式。
        case rejectedIdentifier(String)
        /// 启动失败。
        case launchFailed(String)

        var description: String {
            switch self {
            case .invalidExecutable(let path):
                return "不可执行的二进制：\(path)"
            case .rejectedIdentifier(let value):
                return "标识未通过白名单校验：\(value)"
            case .launchFailed(let reason):
                return "进程启动失败：\(reason)"
            }
        }
    }

    /// 同步执行进程（**不经过 shell**），`arguments` 原样作为 argv 传递。
    ///
    /// - Parameters:
    ///   - executable: 可执行文件绝对路径（如 `/usr/bin/hdiutil`）。
    ///   - arguments: 参数数组（不会被 shell 解释）。
    ///   - environment: 可选环境变量（如 brew 需要 PATH）。
    /// - Returns: 退出码与合并输出。
    @discardableResult
    static func run(executable: String,
                    arguments: [String] = [],
                    environment: [String: String]? = nil) throws -> Result {
        let process = makeProcess(executable: executable, arguments: arguments, environment: environment)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(data: data, encoding: .utf8) ?? "")
    }

    /// 启动后立即返回（不等待退出），用于自更新脚本等需要脱离父进程存活的后台任务。
    @discardableResult
    static func runDetached(executable: String,
                            arguments: [String] = [],
                            environment: [String: String]? = nil) throws -> Process {
        let process = makeProcess(executable: executable, arguments: arguments, environment: environment)
        do {
            try process.run()
        } catch {
            throw RunnerError.launchFailed(error.localizedDescription)
        }
        return process
    }

    private static func makeProcess(executable: String,
                                    arguments: [String],
                                    environment: [String: String]?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment = environment {
            process.environment = environment
        }
        return process
    }

    // MARK: - Path discovery (without shell)

    /// Homebrew 可执行文件路径（Apple Silicon `/opt/homebrew/bin/brew`，Intel `/usr/local/bin/brew`）。
    static func brewPath() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 环境变量：给 brew 之类需要 PATH 的子进程使用（替代 `bash -l` 的 profile 加载）。
    static let defaultSearchEnvironment: [String: String] = [
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    ]

    /// 按名字在常见目录中解析可执行文件（替代 shell 的 PATH 查找，不做 word splitting）。
    ///
    /// - Parameters:
    ///   - name: 可执行文件名（须通过 `isValidExternalIdentifier`）。
    ///   - extraSearchPaths: 额外搜索目录（优先于默认目录）。
    /// - Returns: 可执行文件绝对路径；未找到或名字非法时返回 `nil`。
    static func resolveExecutable(named name: String, extraSearchPaths: [String] = []) -> String? {
        guard isValidExternalIdentifier(name) else { return nil }
        var directories = extraSearchPaths
        directories.append(contentsOf: [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
        ])
        for directory in directories {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
