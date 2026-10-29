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
                    .lineSpacing(typography.chatLineSpacing(size: typography.chatSize))
                    .tracking(typography.chatTracking(size: typography.chatSize))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(palette.bubble, in: .rect(cornerRadius: 10))
            }
        case .assistant(_, let text):
            MarkdownText(text: text)
        case .reasoning, .tool:
            // 由 ProcessView 成组显示
            EmptyView()
        case .notice(_, let text):
            Label(text, systemImage: "info.circle")
                .uiFont(12).foregroundStyle(palette.ink3)
        }
    }
}

struct LiveMessageView: View {
    let live: Transcript.Live

    var body: some View {
        // 思考归进上面的过程块，这里只放正文
        if !live.text.isEmpty {
            MarkdownText(text: live.text, streaming: true)
        }
    }
}

/// 两段正文之间的一段过程：收起时只占一行摘要，运行中这一行原地换成当前一步。
/// 设计稿 deliverables/Westie/reviews/2026-10-29-tool-steps/v1。
struct ProcessView: View {
    let steps: [Transcript.Item]
    /// 还在流式生成、没落盘的思考。
    var liveReasoning: String?
    var active = false
    #if DEBUG
    // 后台截图用：WESTIE_PROCESS_EXPANDED=1 时默认展开
    @State private var expanded = ProcessInfo.processInfo.environment["WESTIE_PROCESS_EXPANDED"] == "1"
    #else
    @State private var expanded = false
    #endif
    @State private var hovering = false
    @Environment(\.palette) private var palette

    private var calls: [Transcript.ToolCall] {
        steps.compactMap { if case .tool(let call) = $0 { call } else { nil } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if active {
                        ProgressView().controlSize(.mini).frame(width: 9, height: 9).scaleEffect(0.8)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(palette.ink4)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 9, height: 9)
                    }
                    label
                        .id(labelKey)
                        .transition(.asymmetric(
                            insertion: .offset(y: 6).combined(with: .opacity),
                            removal: .offset(y: -6).combined(with: .opacity)
                        ))
                        .lineLimit(1).truncationMode(.middle)
                }
                .uiFont(12)
                .foregroundStyle(hovering ? palette.ink2 : palette.ink3)
                .frame(height: 24)
                .padding(.leading, 6).padding(.trailing, 8)
                .background(hovering ? palette.rowHoverSolid : .clear, in: .rect(cornerRadius: Metrics.rowRadius))
                .clipped()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hovering = $0 }
            .animation(.smooth(duration: 0.22), value: labelKey)
            .accessibilityValue(expanded ? "已展开" : "已收起")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { step in ProcessStepRow(step: step) }
                    if let liveReasoning, !liveReasoning.isEmpty {
                        ProcessStepRow(step: .reasoning(id: "live", text: liveReasoning))
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(palette.cardStroke).frame(width: 1) }
                .padding(.leading, 4).padding(.top, 4).padding(.bottom, 2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 运行中显示当前一步；结束后显示按类计数的摘要。
    private var labelKey: String {
        guard active else { return "done" }
        if liveReasoning?.isEmpty == false { return "thinking" }
        if let call = calls.last(where: \.isRunning) { return call.id }
        return "thinking"
    }

    @ViewBuilder private var label: some View {
        if active, let call = calls.last(where: \.isRunning), liveReasoning?.isEmpty != false {
            Text("\(Self.verb(call.kind)) · ") + Text(call.stepText).foregroundStyle(palette.ink2)
        } else if active {
            Text("思考中…")
        } else {
            summary
        }
    }

    private var summary: Text {
        let counts = Dictionary(grouping: calls, by: \.kind).mapValues(\.count)
        let parts: [String] = Transcript.ToolCall.Kind.allCases.compactMap { kind in
            guard let n = counts[kind] else { return nil }
            return switch kind {
            case .read: "读取 \(n) 个文件"
            case .edit: "修改 \(n) 个文件"
            case .run: "运行 \(n) 条命令"
            case .search: "搜索 \(n) 次"
            case .web: "打开 \(n) 个网页"
            case .other: "调用 \(n) 个工具"
            }
        }
        let text = Text(parts.isEmpty ? "思考过程" : parts.joined(separator: "，"))
        let fails = calls.filter(\.isError).count
        guard fails > 0 else { return text }
        return text + Text(" · ") + Text("\(fails) 条失败").foregroundStyle(palette.bad)
    }

    static func verb(_ kind: Transcript.ToolCall.Kind) -> String {
        switch kind {
        case .read: "读取"
        case .edit: "修改"
        case .run: "运行"
        case .search: "搜索"
        case .web: "打开"
        case .other: "调用"
        }
    }
}

/// 展开后的一步：动作 + 一行描述，再点开看输出或完整的思考。
private struct ProcessStepRow: View {
    let step: Transcript.Item
    @State private var open = false
    @State private var hovering = false
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.2)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(verb).foregroundStyle(palette.ink4).frame(width: 30, alignment: .leading)
                    Text(line).foregroundStyle(lineColor).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if running { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                }
                .uiFont(12)
                .frame(height: 24)
                .padding(.horizontal, 6)
                .background(hovering ? palette.rowHoverSolid : .clear, in: .rect(cornerRadius: 5))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.leading, -6)
            .onHover { hovering = $0 }

            if open { detail.transition(.opacity) }
        }
    }

    private var call: Transcript.ToolCall? {
        if case .tool(let call) = step { call } else { nil }
    }

    private var running: Bool { call?.isRunning ?? false }

    private var verb: String {
        call.map { ProcessView.verb($0.kind) } ?? "思考"
    }

    private var line: String {
        if let call { return call.stepText }
        if case .reasoning(_, let text) = step {
            return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        }
        return ""
    }

    private var lineColor: Color {
        if call?.isError == true { return palette.bad }
        return call == nil ? palette.ink4 : palette.ink2
    }

    @ViewBuilder private var detail: some View {
        if let call {
            if let result = call.result, !result.isEmpty {
                ScrollView {
                    Text(result)
                        .font(typography.codeFont(size: typography.codeSize - 1))
                        .foregroundStyle(palette.ink3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(palette.code, in: .rect(cornerRadius: 8))
                .padding(.leading, 36).padding(.top, 2).padding(.bottom, 6)
            }
        } else if case .reasoning(_, let text) = step {
            // 思考是正文的旁白：对话字体，小一号、淡一档
            Text(text)
                .font(typography.chat(size: typography.chatSize - 1))
                .lineSpacing(typography.chatLineSpacing(size: typography.chatSize - 1))
                .tracking(typography.chatTracking(size: typography.chatSize - 1))
                .foregroundStyle(palette.ink3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 36).padding(.top, 2).padding(.bottom, 8)
        }
    }
}
