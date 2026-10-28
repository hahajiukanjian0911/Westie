import SwiftUI
import WestieKit

struct TranscriptItemView: View {
    let item: Transcript.Item
    @Environment(\.palette) private var palette

    var body: some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(palette.bubble, in: .rect(cornerRadius: 10))
            }
        case .reasoning(_, let text):
            ReasoningView(text: text, streaming: false)
        case .assistant(_, let text):
            MarkdownText(text: text)
        case .tool(let call):
            ToolCallView(call: call)
        case .notice(_, let text):
            Label(text, systemImage: "info.circle")
                .font(.callout).foregroundStyle(palette.ink3)
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
    @Environment(\.palette) private var palette

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.callout).foregroundStyle(palette.ink3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(streaming ? "思考中…" : "思考过程")
                .font(.callout).foregroundStyle(palette.ink3)
        }
    }
}

struct ToolCallView: View {
    let call: Transcript.ToolCall
    @State private var expanded = false
    @Environment(\.palette) private var palette

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
                .background(palette.code, in: .rect(cornerRadius: 10))
            }
        } label: {
            HStack(spacing: 6) {
                if call.isRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: call.isError ? "xmark.circle" : "checkmark.circle")
                        .foregroundStyle(call.isError ? palette.bad : palette.ink3)
                }
                Text(call.name).font(.system(.callout, design: .monospaced)).foregroundStyle(palette.ink2)
                Text(call.summary).font(.callout).foregroundStyle(palette.ink3).lineLimit(1)
            }
        }
    }
}

/// 轻量 Markdown：围栏代码块等宽显示，其余按行内语法渲染并保留换行。
struct MarkdownText: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, segment in
                if segment.isCode {
                    Text(segment.text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(palette.ink2)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(palette.code, in: .rect(cornerRadius: 10))
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
