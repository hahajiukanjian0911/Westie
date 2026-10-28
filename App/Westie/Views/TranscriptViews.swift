import SwiftUI
import Textual
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

/// Markdown 用 Textual 渲染：段落、列表、标题、引用、表格、代码块，可以跨块选中文本。
/// 代码块、引用和行内代码的颜色取自配色，其余沿用 Textual 默认样式。
struct MarkdownText: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        StructuredText(markdown: text)
            .textual.textSelection(.enabled)
            .textual.inlineStyle(
                InlineStyle()
                    .code(.monospaced, .fontScale(0.92), .backgroundColor(DynamicColor(palette.bubble)))
                    .strong(.fontWeight(.semibold))
                    .link(.foregroundColor(DynamicColor(palette.accent)))
            )
            .textual.codeBlockStyle(PaletteCodeBlockStyle(palette: palette))
            .textual.blockQuoteStyle(PaletteBlockQuoteStyle(palette: palette))
            .textual.highlighterTheme(Self.theme(palette))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 代码高亮只用配色里已有的几种颜色，克制一些。
    static func theme(_ palette: Palette) -> StructuredText.HighlighterTheme {
        let keyword = AnyTextProperty(.foregroundColor(DynamicColor(palette.accent)))
        let string = AnyTextProperty(.foregroundColor(DynamicColor(palette.ok)))
        let number = AnyTextProperty(.foregroundColor(DynamicColor(palette.warn)))
        let comment = AnyTextProperty(.foregroundColor(DynamicColor(palette.ink4)))
        return .init(
            foregroundColor: DynamicColor(palette.ink2),
            backgroundColor: DynamicColor(palette.code),
            tokenProperties: [
                .keyword: keyword, .literal: keyword, .boolean: keyword,
                .string: string, .char: string, .regex: string,
                .number: number,
                .comment: comment,
            ]
        )
    }
}

private struct PaletteCodeBlockStyle: StructuredText.CodeBlockStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .textual.lineSpacing(.fontScaled(0.35))
                .textual.fontScale(0.92)
                .fixedSize(horizontal: false, vertical: true)
                .monospaced()
                .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(palette.code, in: .rect(cornerRadius: 10))
        .textual.blockSpacing(.fontScaled(top: 0.8, bottom: 0))
    }
}

private struct PaletteBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule().fill(palette.ink5).frame(width: 3)
            }
    }
}
