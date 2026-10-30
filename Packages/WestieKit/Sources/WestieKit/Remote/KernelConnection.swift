import Foundation

/// 内核 Remote 调用返回的业务或网关错误（`gateway/*`、各业务包自己的错误码）。
public struct RemoteFailure: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    public var details: JSONValue?
}

public enum ConnectionError: Error, Sendable, Equatable {
    case connectRejected(status: Int)
    case badResponse(String)
    case disconnected
}

/// 内核转发给客户端的事件（`$events` 流里 ready 之后的帧）。
public enum RemoteEvent: Sendable {
    /// 单向通知。
    case emit(event: String, args: [JSONValue])
    /// 需要客户端作答的 Agent 级 waterfall（审批等）；用 `answerEvent` 回复。
    case waterfall(event: String, eventId: String, agentId: String, request: JSONValue)
    /// 内核撤回了之前下发的 waterfall。
    case cancel(eventId: String)
}

/// 与一个内核的连接：以 API Peer 身份接入，承载一元调用、多路复用流与转发事件。
///
/// API Peer 的生命周期绑定在 mux WebSocket 上：socket 断开后 cookie 失效，必须重新 `connect`。
public actor KernelConnection {
    public enum Interactions: String, Sendable {
        /// 接收并作答转发事件（审批、提问）。App 主连接用这个。
        case answer
        /// 只调用，不接事件。
        case none
    }

    public nonisolated let endpoint: KernelEndpoint
    private let session: URLSession
    private var cookie: String?
    private var socket: URLSessionWebSocketTask?
    private var streams: [String: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var nextStreamId = 0
    private var eventClientId: String?
    private var eventContinuation: AsyncStream<RemoteEvent>.Continuation?

    /// 内核宿主的 home 目录（用于缩写显示路径），接入后可用。
    public private(set) var hostHome: String?
    public private(set) var isConnected = false

    public init(endpoint: KernelEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 300
        session = URLSession(configuration: configuration)
    }

    // MARK: - 接入

    /// 用启动令牌换 API cookie，打开 mux socket；`answer` 模式下同时建立事件流并等到 ready。
    /// 返回的事件序列在连接断开时结束。
    @discardableResult
    public func connect(interactions: Interactions = .answer) async throws -> AsyncStream<RemoteEvent> {
        var components = URLComponents(url: endpoint.origin.appending(path: "connect"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "token", value: endpoint.token),
            URLQueryItem(name: "interactions", value: interactions.rawValue),
        ]
        let (_, response) = try await session.data(for: URLRequest(url: components.url!), delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse, http.statusCode == 302,
              let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let pair = setCookie.split(separator: ";").first, pair.hasPrefix("dsh-auth-")
        else {
            throw ConnectionError.connectRejected(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        PerfTrace.mark("connect_http_ready")
        cookie = String(pair)

        var socketURL = URLComponents(url: endpoint.origin.appending(path: "api/remote.mux"), resolvingAgainstBaseURL: false)!
        socketURL.scheme = endpoint.origin.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: socketURL.url!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 64 << 20
        self.socket = socket
        socket.resume()
        isConnected = true
        Task { await receiveLoop(socket) }

        let (events, continuation) = AsyncStream<RemoteEvent>.makeStream()
        eventContinuation = continuation
        guard interactions == .answer else { return events }

        // 事件流的首帧是 ready：带客户端代次 id 与宿主信息。
        let eventFrames = stream("$events", [:])
        var iterator = eventFrames.makeAsyncIterator()
        guard let ready = try await iterator.next(), ready["type"]?.stringValue == "ready",
              let clientId = ready["clientId"]?.stringValue
        else { throw ConnectionError.badResponse("$events 首帧不是 ready") }
        eventClientId = clientId
        hostHome = ready["host"]?["home"]?.stringValue
        Task { [iterator] in
            var iterator = iterator
            while let frame = try? await iterator.next() {
                if let event = Self.decodeEvent(frame) { continuation.yield(event) }
            }
            continuation.finish()
        }
        return events
    }

    public func disconnect() {
        socket?.cancel(with: .normalClosure, reason: nil)
        tearDown()
    }

    // MARK: - 调用

    /// 一元调用：`POST /api/<endpoint>`。业务失败抛 `RemoteFailure`。
    public func call(_ endpointName: String, _ args: JSONValue = [:]) async throws -> JSONValue {
        guard let cookie, isConnected else { throw ConnectionError.disconnected }
        var request = URLRequest(url: endpoint.origin.appending(path: "api/\(endpointName)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let rpcId = UUID().uuidString
        let envelope: JSONValue = [
            "type": "client-request", "rpcId": .string(rpcId), "method": .string(endpointName),
            "payload": ["args": args],
        ]
        request.httpBody = try JSONEncoder().encode(envelope)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ConnectionError.badResponse("\(endpointName): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        guard reply["rpcId"]?.stringValue == rpcId, let result = reply["result"] else {
            throw ConnectionError.badResponse("\(endpointName): 响应信封不匹配")
        }
        if result["ok"]?.boolValue == true { return result["value"] ?? .null }
        throw Self.failure(from: result["error"])
    }

    /// 打开一条流式调用。迭代结束即内核发 end；提前停止迭代会向内核发 cancel。
    public func stream(_ endpointName: String, _ args: JSONValue = [:]) -> AsyncThrowingStream<JSONValue, Error> {
        nextStreamId += 1
        let streamId = "s\(nextStreamId)"
        let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
        guard let socket, isConnected else {
            continuation.finish(throwing: ConnectionError.disconnected)
            return stream
        }
        streams[streamId] = continuation
        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.cancelStream(streamId) }
        }
        let frame: JSONValue = [
            "type": "open", "streamId": .string(streamId), "endpoint": .string(endpointName),
            "payload": ["args": args],
        ]
        send(frame, on: socket)
        return stream
    }

    /// 回复一个 waterfall 事件：`next` 交给后续处理者，`result` 给出结果。
    public func answerEvent(eventId: String, result value: JSONValue?) async throws {
        guard let eventClientId else { throw ConnectionError.disconnected }
        var outcome: JSONValue = ["kind": "next"]
        if let value { outcome = ["kind": "result", "value": value] }
        _ = try await call("$events/result", [
            "clientId": .string(eventClientId), "eventId": .string(eventId), "outcome": outcome,
        ])
    }

    // MARK: - Mux

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() } catch { break }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            guard let frame = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let streamId = frame["streamId"]?.stringValue,
                  let continuation = streams[streamId]
            else { continue }
            switch frame["type"]?.stringValue {
            case "item":
                continuation.yield(frame["value"] ?? .null)
            case "end":
                streams[streamId] = nil
                continuation.finish()
            case "error":
                streams[streamId] = nil
                continuation.finish(throwing: Self.failure(from: frame["error"]))
            default:
                continue
            }
        }
        if self.socket === socket { tearDown() }
    }

    private func cancelStream(_ streamId: String) {
        guard streams.removeValue(forKey: streamId) != nil, let socket else { return }
        send(["type": "cancel", "streamId": .string(streamId)], on: socket)
    }

    private func send(_ frame: JSONValue, on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONEncoder().encode(frame), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    private func tearDown() {
        isConnected = false
        socket = nil
        cookie = nil
        eventClientId = nil
        for continuation in streams.values { continuation.finish(throwing: ConnectionError.disconnected) }
        streams.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    // MARK: - 解码

    private static func failure(from error: JSONValue?) -> RemoteFailure {
        RemoteFailure(
            code: error?["code"]?.stringValue ?? "unknown",
            message: error?["message"]?.stringValue ?? "",
            details: error?["details"]
        )
    }

    private static func decodeEvent(_ frame: JSONValue) -> RemoteEvent? {
        switch frame["type"]?.stringValue {
        case "emit":
            guard let event = frame["event"]?.stringValue else { return nil }
            return .emit(event: event, args: frame["args"]?.arrayValue ?? [])
        case "waterfall":
            guard let event = frame["event"]?.stringValue, let eventId = frame["eventId"]?.stringValue,
                  let agentId = frame["agentId"]?.stringValue
            else { return nil }
            return .waterfall(event: event, eventId: eventId, agentId: agentId, request: frame["request"] ?? .null)
        case "cancel":
            guard let eventId = frame["eventId"]?.stringValue else { return nil }
            return .cancel(eventId: eventId)
        default:
            return nil
        }
    }
}

/// `/connect` 返回 302，不能跟随跳转，否则拿不到 Set-Cookie。
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
