import Foundation
import WestieKit

/// 内核从哪里来、怎么启动。
struct KernelConfiguration {
    var location: KernelLocation
    var options: KernelProcess.Options

    /// 开发期：内核与 DSH_HOME 都在仓库里（temp/dsh-home，与真实的 ~/.dsh 隔离），并清除 API key，
    /// 开发中不会发出真实模型请求。设了 `WESTIE_MOCK_LLM=<端口>` 时，DeepSeek 提供方改指本地
    /// scripts/mock-llm.mjs，可以安全地发消息。打包版的内核位置在打包阶段再接。
    static func development() throws -> KernelConfiguration {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var options = KernelProcess.Options()
        options.scrubCredentials = true
        options.logFile = repoRoot.appending(path: "temp/logs/kernel.log")
        if let port = ProcessInfo.processInfo.environment["WESTIE_MOCK_LLM"] {
            options.environment["DEEPSEEK_API_KEY"] = "westie-mock"
            options.environment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:\(port)"
        }
        return KernelConfiguration(location: try .development(repoRoot: repoRoot), options: options)
    }
}
