import Darwin
import Foundation

public enum KernelError: Error, Equatable, Sendable {
    case nodeNotFound
    case exitedBeforeReady(status: Int32)
    case startupTimedOut
    case noFreePort
}

/// 内核就绪后打印的连接地址：`http://127.0.0.1:<port>/?token=…`。
public struct KernelEndpoint: Sendable, Equatable {
    public var origin: URL
    public var token: String

    /// 解析内核 stdout 的就绪行 `dsh web: <url>`。
    public init?(readyLine line: Substring) {
        let prefix = "dsh web: "
        guard line.hasPrefix(prefix),
              let components = URLComponents(string: String(line.dropFirst(prefix.count))),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value,
              let scheme = components.scheme, let host = components.host, let port = components.port,
              let origin = URL(string: "\(scheme)://\(host):\(port)")
        else { return nil }
        self.origin = origin
        self.token = token
    }
}

/// 管理一个内核子进程：首次运行时初始化 profile，拉起内核，等它打印连接地址，退出时结束它。
public actor KernelProcess {
    public static let profileName = "westie"

    public struct Options: Sendable {
        /// 清除模型提供方的 API key 环境变量。测试必须开启，避免任何真实模型请求。
        public var scrubCredentials = false
        public var startupTimeout: Duration = .seconds(90)
        /// 内核 stdout/stderr 的追加日志文件。
        public var logFile: URL?

        public init() {}
    }

    private let location: KernelLocation
    private let options: Options
    private var process: Process?

    public init(location: KernelLocation, options: Options = Options()) {
        self.location = location
        self.options = options
    }

    /// 拉起内核并等待就绪，返回连接地址。已在运行时直接报错由调用方处理（不重复拉起）。
    public func start() async throws -> KernelEndpoint {
        precondition(process == nil, "kernel already started")
        try await ensureProfile()

        let port = try Self.freeLoopbackPort()
        let child = makeProcess(arguments: ["--profile", Self.profileName, "--no-open", "--port", String(port)])
        let stdout = Pipe()
        child.standardOutput = stdout
        child.standardError = logHandle() ?? FileHandle.nullDevice
        try child.run()
        process = child

        let log = logHandle()
        let timeout = options.startupTimeout
        do {
            return try await withThrowingTaskGroup(of: KernelEndpoint.self) { group in
                group.addTask {
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        log?.write(Data((line + "\n").utf8))
                        if let endpoint = KernelEndpoint(readyLine: line[...]) {
                            // 就绪后继续把 stdout 抽进日志，防止管道写满阻塞内核。
                            Task.detached {
                                do {
                                    for try await rest in stdout.fileHandleForReading.bytes.lines {
                                        log?.write(Data((rest + "\n").utf8))
                                    }
                                } catch {}
                            }
                            return endpoint
                        }
                    }
                    child.waitUntilExit()
                    throw KernelError.exitedBeforeReady(status: child.terminationStatus)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw KernelError.startupTimedOut
                }
                let endpoint = try await group.next()!
                group.cancelAll()
                return endpoint
            }
        } catch {
            await stop()
            throw error
        }
    }

    /// 先 SIGTERM 让内核排空持久化，5 秒内没退出再 SIGKILL。
    public func stop() async {
        guard let child = process else { return }
        process = nil
        guard child.isRunning else { return }
        child.terminate()
        for _ in 0..<50 where child.isRunning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Profile

    static let bundles = ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "@westie/kernel-bundle"]

    /// 准备 profile：Westie 组合包是纯 patch 包，每次启动直接复制进 profile 的 node_modules
    /// （不需要 pnpm，App 升级时随之刷新）；清单只在首次创建。
    /// profile 的 `cordis.patch.yml` 归内核所有（保存默认模型等会写回它），这里从不触碰。
    private func ensureProfile() async throws {
        let fileManager = FileManager.default
        let installed = location.profileDirectory.appending(path: "node_modules/@westie/kernel-bundle")
        try fileManager.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: installed.path) { try fileManager.removeItem(at: installed) }
        try fileManager.copyItem(at: location.bundleDirectory, to: installed)

        let manifest = location.profileDirectory.appending(path: "package.json")
        guard !fileManager.fileExists(atPath: manifest.path) else { return }
        let profile: JSONValue = [
            "name": "westie-profile",
            "private": true,
            "dsh": ["profile": ["bundles": .array(Self.bundles.map(JSONValue.string))]],
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(profile).write(to: manifest)
    }

    // MARK: - Helpers

    private func makeProcess(arguments: [String]) -> Process {
        let child = Process()
        child.executableURL = location.node
        child.arguments = [location.launchScript.path] + arguments
        child.currentDirectoryURL = location.kernelRoot
        var environment = ProcessInfo.processInfo.environment
        environment["DSH_HOME"] = location.dshHome.path
        if options.scrubCredentials {
            for key in environment.keys where key.hasSuffix("_API_KEY") {
                environment.removeValue(forKey: key)
            }
        }
        child.environment = environment
        return child
    }

    private func logHandle() -> FileHandle? {
        guard let url = options.logFile else { return nil }
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        return handle
    }

    /// 让系统分配一个空闲的回环端口。
    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KernelError.noFreePort }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw KernelError.noFreePort }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
