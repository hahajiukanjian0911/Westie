import Foundation
import Observation
import WestieKit

/// App 层持有的内核：启动时拉起并接入，退出时结束。
@MainActor @Observable
final class KernelHost {
    enum State: Equatable {
        case starting
        case connected(sessions: Int)
        case failed(String)
    }

    private(set) var state: State = .starting
    private var kernel: KernelProcess?
    private(set) var connection: KernelConnection?

    func start() async {
        do {
            let (location, options) = try Self.configuration()
            let kernel = KernelProcess(location: location, options: options)
            self.kernel = kernel
            let connection = KernelConnection(endpoint: try await kernel.start())
            try await connection.connect(interactions: .answer)
            self.connection = connection
            let sessions = try await connection.call("session/list", ["_request": [:]])
            state = .connected(sessions: sessions["items"]?.arrayValue?.count ?? 0)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func stop() async {
        await connection?.disconnect()
        await kernel?.stop()
    }

    /// 开发期：内核与 DSH_HOME 都在仓库里（temp/dsh-home 与用户真实的 ~/.dsh 隔离），
    /// 并清除 API key，开发中不会发出真实模型请求。打包版的内核位置在打包阶段再接。
    private static func configuration() throws -> (KernelLocation, KernelProcess.Options) {
        let repoRoot = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var options = KernelProcess.Options()
        options.scrubCredentials = true
        options.logFile = repoRoot.appending(path: "temp/logs/kernel.log")
        return (try KernelLocation.development(repoRoot: repoRoot), options)
    }
}
