import Foundation

/// 一个会话的对话记录：把 `session/follow` 的快照记录、日志事件与实时助手流折叠成可显示的条目。
public struct Transcript: Sendable, Equatable {
    public enum Item: Sendable, Identifiable, Equatable {
        case user(id: String, text: String)
        case reasoning(id: String, text: String)
        case assistant(id: String, text: String)
        case tool(ToolCall)
        case notice(id: String, text: String)

        public var id: String {
            switch self {
            case .user(let id, _), .reasoning(let id, _), .assistant(let id, _), .notice(let id, _): id
            case .tool(let call): call.id
            }
        }
    }

    public struct ToolCall: Sendable, Equatable {
        public var id: String
        public var name: String
        public var arguments: JSONValue
        public var result: String?
        public var isError = false

        public var isRunning: Bool { result == nil }

        /// 一行摘要：bash 显示命令，其余显示描述或第一个参数。
        public var summary: String {
            for key in ["description", "command", "file_path", "pattern", "url", "prompt"] {
                if let text = arguments[key]?.stringValue, !text.isEmpty { return text }
            }
            return ""
        }
    }

    /// 正在流式生成、尚未落盘的助手消息。
    public struct Live: Sendable, Equatable {
        public var reasoning = ""
        public var text = ""
    }

    public private(set) var items: [Item] = []
    public private(set) var live: Live?
    public private(set) var running = false
    public private(set) var lastSeq = -1
    private var toolIndex: [String: Int] = [:]

    public init() {}

    // MARK: - 应用 follow 帧

    /// 应用一帧 `session/follow` 输出（snapshot / event / assistant-stream）。
    public mutating func apply(followFrame frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "snapshot":
            for record in frame["records"]?.arrayValue ?? [] where record["type"]?.stringValue == "event" {
                if let event = record["event"] { apply(event: event) }
            }
        case "event":
            if let event = frame["event"] { apply(event: event) }
        case "assistant-stream":
            if let streamFrame = frame["frame"] { apply(streamFrame: streamFrame) }
        default:
            break
        }
    }

    public mutating func apply(event: JSONValue) {
        guard case .number(let seqValue) = event["seq"] else { return }
        let seq = Int(seqValue)
        guard seq > lastSeq else { return }
        lastSeq = seq
        let data = event["data"] ?? .null

        switch event["type"]?.stringValue {
        case "user/message":
            guard data["source"]?["kind"]?.stringValue == "user" else { return }
            items.append(.user(id: "\(seq)", text: Self.text(of: data["content"])))
        case "assistant/message":
            live = nil
            for (index, block) in (data["message"]?["content"]?.arrayValue ?? []).enumerated() {
                let id = "\(seq).\(index)"
                switch block["type"]?.stringValue {
                case "reasoning":
                    let text = block["text"]?.stringValue ?? ""
                    if !text.isEmpty { items.append(.reasoning(id: id, text: text)) }
                case "text":
                    let text = block["text"]?.stringValue ?? ""
                    if !text.isEmpty { items.append(.assistant(id: id, text: text)) }
                case "tool-call":
                    guard let callId = block["id"]?.stringValue else { continue }
                    let arguments = block["arguments"]?.stringValue
                        .flatMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) } ?? .null
                    toolIndex[callId] = items.count
                    items.append(.tool(ToolCall(id: callId, name: block["name"]?.stringValue ?? "tool", arguments: arguments)))
                default:
                    continue
                }
            }
        case "tool/result":
            let message = data["message"] ?? .null
            guard let callId = message["toolCallId"]?.stringValue, let index = toolIndex[callId],
                  case .tool(var call) = items[index]
            else { return }
            call.result = Self.text(of: message["content"])
            call.isError = message["isError"]?.boolValue ?? false
            items[index] = .tool(call)
        case "turn/start":
            running = true
        case "turn/end":
            running = false
            live = nil
            let kind = data["reason"]?["kind"]?.stringValue ?? "completed"
            if kind != "completed" {
                let detail = data["reason"]?["message"]?.stringValue ?? data["reason"]?["error"]?["message"]?.stringValue
                items.append(.notice(id: "\(seq)", text: Self.turnEndNotice(kind: kind, detail: detail)))
            }
        default:
            break
        }
    }

    public mutating func apply(streamFrame frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "start":
            live = Live()
        case "chunk":
            let chunk = frame["chunk"] ?? .null
            switch chunk["type"]?.stringValue {
            case "reasoning-delta": live?.reasoning += chunk["text"]?.stringValue ?? ""
            case "text-delta": live?.text += chunk["text"]?.stringValue ?? ""
            default: break
            }
        case "end":
            live = nil
        default:
            break
        }
    }

    // MARK: - Helpers

    static func text(of content: JSONValue?) -> String {
        if let text = content?.stringValue { return text }
        return (content?.arrayValue ?? []).compactMap { block -> String? in
            switch block["type"]?.stringValue {
            case "text": block["text"]?.stringValue
            case "image": "［图片］"
            default: nil
            }
        }.joined(separator: "\n")
    }

    static func turnEndNotice(kind: String, detail: String?) -> String {
        let title = switch kind {
        case "cancelled", "interrupted", "aborted": "已停止"
        case "error", "failed": "出错了"
        default: "回合结束（\(kind)）"
        }
        guard let detail, !detail.isEmpty else { return title }
        return "\(title)：\(detail)"
    }
}
