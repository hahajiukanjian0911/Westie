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

    /// 默认数据放在 Westie 自己的 `~/.config/westie/dsh`，与 DSH.app 的 `~/.dsh` 完全分开，两者可以同时运行。
    /// `WESTIE_DSH_HOME=<目录>` 可另指数据目录；指回真实 `~/.dsh` 时照旧与 DSH.app 互斥。
    ///
    /// `WESTIE_MOCK_LLM=<端口>`：改用仓库里的 temp/dsh-home 并把 DeepSeek 提供方指向本地
    /// scripts/mock-llm.mjs，测试会话永远不会写进真实数据。打包版的内核位置在打包阶段再接。
    static func development() throws -> KernelConfiguration {
        let environment = ProcessInfo.processInfo.environment
        var location = try KernelLocation.development(repoRoot: repoRoot)
        var options = KernelProcess.Options()
        options.logFile = environment["WESTIE_PERF_KERNEL_LOG"].map { URL(filePath: $0) }
            ?? repoRoot.appending(path: "temp/logs/kernel.log")

        if let port = environment["WESTIE_MOCK_LLM"] {
            // 可用 WESTIE_DSH_HOME 另指一份测试数据，和已开着的假模型实例互不干扰。
            location.dshHome = environment["WESTIE_DSH_HOME"].map { URL(filePath: $0) }
                ?? repoRoot.appending(path: "temp/dsh-home")
            // 假模型会建会话、发消息，绝不能落到真实数据（Westie 自己的或 DSH.app 的）
            guard !isRealDSHHome(location.dshHome), Self.same(location.dshHome, ConfigHome.dshHome) == false else { throw KernelConfigurationError.mockOnRealDSHHome }
            options.scrubCredentials = true
            options.environment["DEEPSEEK_API_KEY"] = "westie-mock"
            options.environment["DEEPSEEK_BASE_URL"] = "http://127.0.0.1:\(port)"
            return KernelConfiguration(location: location, options: options, sharesDSHHome: false, isMock: true)
        }
        if let home = environment["WESTIE_DSH_HOME"] {
            location.dshHome = URL(filePath: home)
        } else {
            location.dshHome = ConfigHome.dshHome
        }
        return KernelConfiguration(location: location, options: options,
                                   sharesDSHHome: isRealDSHHome(location.dshHome), isMock: false)
    }

    /// 开发期仓库根目录：内核、日志与测试数据都在这里。
    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// 按数据目录区分的配置键后缀：默认数据目录不加，其他目录（测试、另指）用路径，互相恢复不出对方的会话窗口。
    var dataScope: String? {
        Self.same(location.dshHome, ConfigHome.dshHome)
            ? nil : location.dshHome.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 按解析符号链接后的路径比较，软链接指过去的也算。
    private static func isRealDSHHome(_ url: URL) -> Bool {
        same(url, FileManager.default.homeDirectoryForCurrentUser.appending(path: ".dsh"))
    }
}

enum KernelConfigurationError: LocalizedError {
    case mockOnRealDSHHome

    var errorDescription: String? {
        "假模型模式不能使用真实数据（~/.config/westie/dsh 或 ~/.dsh），请把 WESTIE_DSH_HOME 指向测试目录。"
    }
}
