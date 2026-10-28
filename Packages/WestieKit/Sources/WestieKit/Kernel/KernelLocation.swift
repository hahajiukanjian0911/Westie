import Foundation

/// 内核的文件位置：Node 可执行文件、启动壳、组合包与 DSH_HOME。
public struct KernelLocation: Sendable {
    /// 运行内核的 Node 可执行文件。
    public var node: URL
    /// `kernel/` 目录：含 `launch.mjs`、`node_modules` 与 `bundle/`。
    public var kernelRoot: URL
    /// 内核的 DSH_HOME（会话、凭据、profile 都在这里）。
    public var dshHome: URL

    public init(node: URL, kernelRoot: URL, dshHome: URL) {
        self.node = node
        self.kernelRoot = kernelRoot
        self.dshHome = dshHome
    }

    public var launchScript: URL { kernelRoot.appending(path: "launch.mjs") }
    public var bundleDirectory: URL { kernelRoot.appending(path: "bundle") }
    public var profileDirectory: URL { dshHome.appending(path: "profiles/\(KernelProcess.profileName)") }

    /// 开发期位置：读环境变量 `WESTIE_KERNEL_ROOT` / `WESTIE_NODE` / `WESTIE_DSH_HOME`，
    /// 缺省时从仓库根推断（kernel/、mise 安装的 Node 24、temp/dsh-home）。
    public static func development(repoRoot: URL) throws -> KernelLocation {
        let environment = ProcessInfo.processInfo.environment
        let kernelRoot = environment["WESTIE_KERNEL_ROOT"].map { URL(filePath: $0) }
            ?? repoRoot.appending(path: "kernel")
        let dshHome = environment["WESTIE_DSH_HOME"].map { URL(filePath: $0) }
            ?? repoRoot.appending(path: "temp/dsh-home")
        let node = try environment["WESTIE_NODE"].map { URL(filePath: $0) } ?? findMiseNode()
        return KernelLocation(node: node, kernelRoot: kernelRoot, dshHome: dshHome)
    }

    private static func findMiseNode() throws -> URL {
        let installs = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/mise/installs/node")
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: installs.path)) ?? []
        guard let major = versions.filter({ $0.hasPrefix("24") }).sorted().last else {
            throw KernelError.nodeNotFound
        }
        return installs.appending(path: "\(major)/bin/node")
    }
}
