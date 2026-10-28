import Foundation
import Testing
@testable import WestieKit

@Test func parsesReadyLine() {
    let endpoint = KernelEndpoint(readyLine: "dsh web: http://127.0.0.1:3181/?token=abc_-1")
    #expect(endpoint?.origin.absoluteString == "http://127.0.0.1:3181")
    #expect(endpoint?.token == "abc_-1")
    #expect(KernelEndpoint(readyLine: "something else") == nil)
}

@Test func allocatesFreePort() throws {
    let port = try KernelProcess.freeLoopbackPort()
    #expect(port > 1024)
}

/// 拉起真实内核（隔离 DSH_HOME、清除 API key），只调只读方法，绝不发 prompt。
/// 需要 `WESTIE_KERNEL_IT=1`；仓库根从本文件位置推断。
@Test(.enabled(if: ProcessInfo.processInfo.environment["WESTIE_KERNEL_IT"] == "1"))
func kernelEndToEnd() async throws {
    let repoRoot = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    var location = try KernelLocation.development(repoRoot: repoRoot)
    location.dshHome = repoRoot.appending(path: "temp/dsh-home-it")
    var options = KernelProcess.Options()
    options.scrubCredentials = true
    options.logFile = repoRoot.appending(path: "temp/logs/kernel-it.log")
    let kernel = KernelProcess(location: location, options: options)

    let clock = ContinuousClock()
    let launched = clock.now
    let endpoint = try await kernel.start()
    let startup = clock.now - launched

    let connection = KernelConnection(endpoint: endpoint)
    try await connection.connect(interactions: .answer)
    #expect(await connection.hostHome == FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false).trimmingSuffix("/"))

    let sessions = try await connection.call("session/list", ["_request": [:]])
    #expect(sessions["items"]?.arrayValue != nil)

    let catalog = try await connection.call("session/modelCatalog")
    #expect(catalog["default"]?["provider"]?.stringValue == "deepseek-official")

    var follow = await connection.stream("workspace/follow").makeAsyncIterator()
    let baseline = try await follow.next()
    #expect(baseline?["type"]?.stringValue == "baseline")

    await #expect(throws: RemoteFailure.self) {
        _ = try await connection.call("session/list", [:])
    }

    await connection.disconnect()
    await kernel.stop()
    #expect(await kernel.isRunning == false)
    print("内核启动耗时：\(startup)")
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
