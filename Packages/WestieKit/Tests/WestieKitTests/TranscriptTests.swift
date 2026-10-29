import Foundation
import Testing
@testable import WestieKit

/// 夹具来自真实内核 + scripts/mock-llm.mjs 录下的 follow 帧（/bash 与 /ask 两个会话）。
private func fixture(_ name: String) throws -> (follow: [JSONValue], workspace: [JSONValue]) {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    return (value["follow"]?.arrayValue ?? [], value["workspace"]?.arrayValue ?? [])
}

@Test func foldsToolTurn() throws {
    var transcript = Transcript()
    for frame in try fixture("bash").follow { transcript.apply(followFrame: frame) }

    let kinds = transcript.items.map { item -> String in
        switch item {
        case .user: "user"
        case .reasoning: "reasoning"
        case .assistant: "assistant"
        case .tool: "tool"
        case .notice: "notice"
        }
    }
    #expect(kinds == ["user", "reasoning", "assistant", "tool", "reasoning", "assistant"])
    guard case .user(_, let prompt) = transcript.items[0] else { Issue.record("首条不是用户消息"); return }
    #expect(prompt == "/bash")
    guard case .tool(let call) = transcript.items[3] else { Issue.record("第 4 条不是工具"); return }
    #expect(call.name == "bash")
    #expect(call.summary == "打印测试文本")
    #expect(call.result == "westie-mock-tool\n")
    #expect(call.isError == false)
    #expect(transcript.running == false)
    #expect(transcript.live == nil)
}

@Test func pendingQuestionLeavesTurnRunning() throws {
    var transcript = Transcript()
    for frame in try fixture("ask").follow { transcript.apply(followFrame: frame) }
    #expect(transcript.running == true)
    guard case .tool(let call) = transcript.items.last else { Issue.record("最后一条不是工具"); return }
    #expect(call.name == "ask_user_question")
    #expect(call.isRunning)
}

@Test func streamsLiveText() {
    var transcript = Transcript()
    transcript.apply(streamFrame: ["type": "start"])
    transcript.apply(streamFrame: ["type": "chunk", "chunk": ["type": "reasoning-delta", "text": "想"]])
    transcript.apply(streamFrame: ["type": "chunk", "chunk": ["type": "text-delta", "text": "你"]])
    transcript.apply(streamFrame: ["type": "chunk", "chunk": ["type": "text-delta", "text": "好"]])
    #expect(transcript.live == Transcript.Live(reasoning: "想", text: "你好"))
    transcript.apply(streamFrame: ["type": "end"])
    #expect(transcript.live == nil)
}

@Test func ignoresReplayedEvents() {
    var transcript = Transcript()
    let event: JSONValue = ["seq": .number(8), "type": "user/message", "data": ["source": ["kind": "user"], "content": .array([["type": "text", "text": "hi"]])]]
    transcript.apply(event: event)
    transcript.apply(event: event)
    #expect(transcript.items.count == 1)
}

@Test func buildsWorkspaceBoard() throws {
    var board = WorkspaceBoard()
    for frame in try fixture("bash").workspace { board.apply(frame) }
    #expect(board.ordered.count == 1)
    #expect(board.ordered.first?.title == "ws1")
    #expect(board.ordered.first?.sessionIds.isEmpty == false)
}

@Test func prependedPageMatchesFullHistory() throws {
    var full = Transcript()
    var events: [JSONValue] = []
    for frame in try fixture("bash").follow {
        full.apply(followFrame: frame)
        if frame["type"]?.stringValue == "snapshot" {
            events += (frame["records"]?.arrayValue ?? []).compactMap { $0["event"] }
        } else if frame["type"]?.stringValue == "event", let event = frame["event"] {
            events.append(event)
        }
    }
    // 切在工具调用和工具结果之间：结果先到（在较新的一页），调用随后翻页补上。
    let resultIndex = try #require(events.firstIndex { $0["type"]?.stringValue == "tool/result" })
    var paged = Transcript()
    events[resultIndex...].forEach { paged.apply(event: $0) }
    paged.prepend(pageRecords: events[..<resultIndex].map { ["type": "event", "event": $0] })

    #expect(paged.items == full.items)
    #expect(paged.firstSeq == full.firstSeq)
    #expect(paged.lastSeq == full.lastSeq)
    #expect(paged.running == full.running)
    // 重复的一页不会再插一遍。
    paged.prepend(pageRecords: events[..<resultIndex].map { ["type": "event", "event": $0] })
    #expect(paged.items == full.items)
}

@Test func groupsProcessBetweenReplies() throws {
    var transcript = Transcript()
    for frame in try fixture("bash").follow { transcript.apply(followFrame: frame) }
    let shape = transcript.blocks.map { block -> String in
        switch block {
        case .item(let item): if case .user = item { "user" } else { "reply" }
        case .process(_, let steps): "process(\(steps.count))"
        }
    }
    #expect(shape == ["user", "process(1)", "reply", "process(2)", "reply"])
    #expect(Set(transcript.blocks.map(\.id)).count == transcript.blocks.count)

    // 第二段过程（工具 + 思考）接在第一段正文后面，起止取自事件时间
    let blocks = transcript.blocks
    guard case .process(_, let steps) = blocks[3], case .item(let previous) = blocks[2] else { Issue.record("结构不对"); return }
    let span = try #require(transcript.span(of: steps, after: previous.id))
    #expect(span.end >= span.start)
    guard case .tool(let call) = steps[0] else { Issue.record("第一步不是工具"); return }
    #expect(call.finishedAt != nil)
}

@Test func classifiesTools() {
    func call(_ name: String, _ arguments: JSONValue = .null) -> Transcript.ToolCall {
        Transcript.ToolCall(id: name, name: name, arguments: arguments)
    }
    #expect(call("read").kind == .read)
    #expect(call("str_replace_editor").kind == .edit)
    #expect(call("terminal_send").kind == .run)
    #expect(call("glob").kind == .search)
    #expect(call("todo_write").kind == .other)
    #expect(call("ask_user_question").kind == .ask)
    #expect(call("ask_user_question").stepText == "向你提问")
    #expect(call("read", .object(["file_path": .string("/Users/a/Development/README.md")])).stepText == "Development/README.md")
}
