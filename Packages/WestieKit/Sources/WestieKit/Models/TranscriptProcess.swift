import Foundation

extension Transcript {
    /// 显示用的块：两段正文之间连续的工具调用与思考合成一个过程块，其余条目照原样。
    /// 过程块的 id 取它前面那一条（`after-<id>`），这样流式中临时的过程块与落盘后的是同一个视图。
    public enum Block: Sendable, Identifiable, Equatable {
        case item(Item)
        case process(id: String, steps: [Item])

        public var id: String {
            switch self {
            case .item(let item): item.id
            case .process(let id, _): id
            }
        }
    }

    public var blocks: [Block] { Self.blocks(items) }

    static func blocks(_ items: [Item]) -> [Block] {
        var blocks: [Block] = []
        var steps: [Item] = []
        func flush() {
            guard !steps.isEmpty else { return }
            blocks.append(.process(id: processId(after: blocks.last), steps: steps))
            steps = []
        }
        for item in items {
            switch item {
            case .reasoning, .tool:
                steps.append(item)
            default:
                flush()
                blocks.append(.item(item))
            }
        }
        flush()
        return blocks
    }

    /// 一段过程的起止：从前一条（用户消息或上一段正文）落盘起，到最后一步结束。
    public func span(of steps: [Item], after previousId: String?) -> (start: Date, end: Date)? {
        let start = previousId.flatMap { times[$0] } ?? steps.first.flatMap { times[$0.id] }
        let end = steps.compactMap { step -> Date? in
            if case .tool(let call) = step { return call.finishedAt ?? times[call.id] }
            return times[step.id]
        }.max()
        guard let start, let end, end >= start else { return nil }
        return (start, end)
    }

    public static func processId(after block: Block?) -> String {
        "after-\(block?.id ?? "start")"
    }
}

extension Transcript.ToolCall {
    /// 摘要按动作计数用的分类。
    public enum Kind: Sendable, CaseIterable {
        case read, edit, run, search, web, other
    }

    public var kind: Kind {
        switch name {
        case "read", "read_image": .read
        case "edit", "write", "str_replace_editor": .edit
        case "bash", "pwsh", "bash_persistent", "pwsh_persistent": .run
        case "grep", "glob", "web_search": .search
        case "web_fetch": .web
        default: name.hasPrefix("terminal_") ? .run : .other
        }
    }

    /// 过程列表里的一行：文件类只留最后两级路径，其余用原摘要。
    public var stepText: String {
        let text = summary
        guard kind == .read || kind == .edit, text.hasPrefix("/") else { return text.isEmpty ? name : text }
        return text.split(separator: "/").suffix(2).joined(separator: "/")
    }
}
