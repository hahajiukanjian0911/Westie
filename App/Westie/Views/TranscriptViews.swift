import SwiftUI
import WestieKit

struct TranscriptItemView: View {
    let item: Transcript.Item

    var body: some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.quaternary, in: .rect(cornerRadius: 12))
            }
        case .reasoning(_, let text):
            ReasoningView(text: text, streaming: false)
        case .assistant(_, let text):
            MarkdownText(text: text)
        case .tool(let call):
            ToolCallView(call: call)
        case .notice(_, let text):
            Label(text, systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct LiveMessageView: View {
    let live: Transcript.Live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !live.reasoning.isEmpty {
                ReasoningView(text: live.reasoning, streaming: live.text.isEmpty)
            }
            if !live.text.isEmpty {
                MarkdownText(text: live.text)
            }
        }
    }
}

struct ReasoningView: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(streaming ? "思考中…" : "思考过程")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ToolCallView: View {
    let call: Transcript.ToolCall
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let result = call.result, !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            }
        } label: {
            HStack(spacing: 6) {
                if call.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: call.isError ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(call.isError ? .red : .secondary)
                }
                Text(call.name).font(.system(.callout, design: .monospaced))
                Text(call.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// 轻量 Markdown：围栏代码块等宽显示，其余按行内语法渲染并保留换行。
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    Text(segment.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                } else {
                    Text(Self.inline(segment.text))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    static func segments(_ text: String) -> [(text: String, isCode: Bool)] {
        var result: [(String, Bool)] = []
        var buffer: [Substring] = []
        var inCode = false
        func flush() {
            let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { result.append((joined, inCode)) }
            buffer = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
            } else {
                buffer.append(line)
            }
        }
        flush()
        return result
    }
}
