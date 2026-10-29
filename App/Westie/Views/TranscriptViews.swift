import SwiftUI
import WestieKit

struct TranscriptItemView: View {
    let item: Transcript.Item
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography

    var body: some View {
        switch item {
        case .user(_, let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .font(typography.chat)
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
                .uiFont(12).foregroundStyle(palette.ink3)
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
                MarkdownText(text: live.text, streaming: true)
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
                .uiFont(12).foregroundStyle(palette.ink3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text(streaming ? "思考中…" : "思考过程")
                .uiFont(12).foregroundStyle(palette.ink3)
        }
    }
}

struct ToolCallView: View {
    let call: Transcript.ToolCall
    @State private var expanded = false
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if let result = call.result, !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(typography.codeFont(size: 11))
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
                Text(call.name).font(typography.codeFont(size: 12)).foregroundStyle(palette.ink2)
                Text(call.summary).uiFont(12).foregroundStyle(palette.ink3).lineLimit(1)
            }
        }
    }
}
