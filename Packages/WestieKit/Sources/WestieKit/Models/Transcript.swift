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
        /// 结果回来的时间。
        public var finishedAt: Date?

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
    /// 每条条目落盘时的事件时间（按条目 id）。
    public private(set) var times: [String: Date] = [:]
    public private(set) var live: Live?
    public private(set) var running = false
    public private(set) var lastSeq = -1
    /// 已加载的最早一条日志事件的 seq；往前翻页时作为 `session/page` 的 beforeSeq。
    public private(set) var firstSeq: Int?
    private var toolIndex: [String: Int] = [:]
    /// 较新页先到的结果：补上调用所在的旧页时，仅修补这些跨页配对。
    private var unmatchedResults: [String: ToolResult] = [:]
    private var hasRunState = false

    private struct ToolResult: Sendable, Equatable {
        var text: String
        var isError: Bool
        var time: Date?
    }

    public struct HistoryPage: Sendable {
        fileprivate var prefix: Transcript
    }

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

    /// 只折叠新取得的旧页；可在主 actor 外准备，不重放已有历史。
    public static func prepareHistoryPage(records: [JSONValue], beforeSeq: Int) -> HistoryPage {
        var prefix = Transcript()
        for record in records {
            guard record["type"]?.stringValue == "event", let event = record["event"],
                  let seq = Self.seq(of: event), seq < beforeSeq else { continue }
            prefix.apply(event: event)
        }
        return HistoryPage(prefix: prefix)
    }

    public mutating func prepend(pageRecords records: [JSONValue]) {
        prepend(historyPage: Self.prepareHistoryPage(records: records, beforeSeq: firstSeq ?? Int.max))
    }

    /// 保留较新条目和 live，仅合并旧页，并修复跨页工具结果与回合状态。
    public mutating func prepend(historyPage page: HistoryPage) {
        var prefix = page.prefix
        guard let olderFirst = prefix.firstSeq, prefix.lastSeq < (firstSeq ?? Int.max) else { return }
        for (id, result) in unmatchedResults {
            if let index = prefix.toolIndex[id] {
                prefix.finishTool(at: index, with: result)
                unmatchedResults.removeValue(forKey: id)
            }
        }
        let offset = prefix.items.count
        items = prefix.items + items
        times = prefix.times.merging(times) { _, newer in newer }
        toolIndex = prefix.toolIndex.merging(toolIndex.mapValues { $0 + offset }) { _, newer in newer }
        unmatchedResults = prefix.unmatchedResults.merging(unmatchedResults) { _, newer in newer }
        if !hasRunState { running = prefix.running }
        hasRunState = hasRunState || prefix.hasRunState
        firstSeq = olderFirst
        lastSeq = max(lastSeq, prefix.lastSeq)
    }

    public mutating func apply(event: JSONValue) {
        guard let seq = Self.seq(of: event), seq > lastSeq else { return }
        lastSeq = seq
        if firstSeq == nil { firstSeq = seq }
        PerfTrace.count("history_events_folded")
        let data = event["data"] ?? .null
        let time: Date? = if case .number(let ms) = event["time"] { Date(timeIntervalSince1970: ms / 1000) } else { nil }
        let before = items.count
        defer {
            if let time { for item in items[before...] { times[item.id] = time } }
        }

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
            guard let callId = message["toolCallId"]?.stringValue else { return }
            let result = ToolResult(text: Self.text(of: message["content"]), isError: message["isError"]?.boolValue ?? false, time: time)
            if let index = toolIndex[callId] {
                finishTool(at: index, with: result)
            } else {
                unmatchedResults[callId] = result
            }
        case "turn/start":
            hasRunState = true
            running = true
        case "turn/end":
            hasRunState = true
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

    private mutating func finishTool(at index: Int, with result: ToolResult) {
        guard case .tool(var call) = items[index] else { return }
        call.result = result.text
        call.isError = result.isError
        call.finishedAt = result.time
        items[index] = .tool(call)
    }

    public mutating func apply(streamFrame frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "start":
            live = Live()
        case "chunk":
            let chunk = frame["chunk"] ?? .null
            switch chunk["type"]?.stringValue {
            case "reasoning-delta": live?.reasoning += chunk["text"]?.stringValue ?? ""
            case "text-delta":
                if PerfTrace.enabled {
                    PerfTrace.count("text_deltas")
                    PerfTrace.count("text_chars", by: Double(chunk["text"]?.stringValue?.count ?? 0))
                }
                live?.text += chunk["text"]?.stringValue ?? ""
            default: break
            }
        case "end":
            live = nil
        default:
            break
        }
    }

    // MARK: - Helpers

    static func seq(of event: JSONValue) -> Int? {
        guard case .number(let value) = event["seq"] else { return nil }
        return Int(value)
    }

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
