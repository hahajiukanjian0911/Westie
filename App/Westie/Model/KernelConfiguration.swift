import Foundation
import WestieKit

/// 内核从哪里来、数据放哪里。
struct KernelConfiguration {
    var location: KernelLocation
    var options: KernelProcess.Options
    /// 数据是用户真实的 `~/.dsh`：必须与 DSH.app 互斥（两个内核同时写 workspace.json 会互相覆盖）。
    var sharesDSHHome: Bool
    /// 假模型模式：数据在仓库 temp/ 里，可以安全地建会话、发消息。
    var isMock: Bool

    /// 默认与 DSH 共用 `~/.dsh`（会话、工作区、登录凭据都沿用）。内核锁定为与 DSH.app 相同的版本，
    /// 写入行为与 DSH.app 完全一致；Westie 只在其中新增 `profiles/westie`。
    ///
    /// `WESTIE_MOCK_LLM=<端口>`：改用仓库里的 temp/dsh-home 并把 DeepSeek 提供方指向本地
    /// scripts/mock-llm.mjs，测试会话永远不会写进真实数据。打包版的内核位置在打包阶段再接。
    static func development() throws -> KernelConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var location = try KernelLocation.development(repoRoot: repoRoot)
        var options = KernelProcess.Options()
        options.logFile = repoRoot.appending(path: "temp/logs/kernel.log")

        if let port = environment["WESTIE_MOCK_LLM"] {
            // 可用 WESTIE_DSH_HOME 另指一份测试数据，和已开着的假模型实例互不干扰。
            location.dshHome = environment["WESTIE_DSH_HOME"].map { URL(filePath: $0) }
                ?? repoRoot.appending(path: "temp/dsh-home")
            options.scrubCredentials = true
            options.environment["DEEPSEEK_API_KEY"] = "westie-mock"
            options.environment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:\(port)"
            return KernelConfiguration(location: location, options: options, sharesDSHHome: false, isMock: true)
        }
        if let home = environment["WESTIE_DSH_HOME"] {
            location.dshHome = URL(filePath: home)
        } else {
            location.dshHome = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dsh")
        }
        let shares = location.dshHome.standardizedFileURL.path
            == FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dsh").standardizedFileURL.path
        return KernelConfiguration(location: location, options: options, sharesDSHHome: shares, isMock: false)
    }
}
