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

/// 两段正文之间的一段过程：收起时只占一行摘要，运行中这一行原地换成当前一步或正在想的那一句。
/// 设计稿 deliverables/Westie/reviews/2026-10-29-tool-steps/v2。
struct ProcessView: View {
    let steps: [Transcript.Item]
    /// 还在流式生成、没落盘的思考。
    var liveReasoning: String?
    var active = false
    /// 总用时（结束后显示在摘要末尾）。
    var duration: TimeInterval?
    /// 每一步的时间（悬停时显示）。
    var times: [String: Date] = [:]
    #if DEBUG
    // 后台截图用：WESTIE_PROCESS_EXPANDED=1 时默认展开
    @State private var expanded = ProcessInfo.processInfo.environment["WESTIE_PROCESS_EXPANDED"] == "1"
    #else
    @State private var expanded = false
    #endif
    @State private var hovering = false
    /// 运行中那一行正显示的思考：只放写完的整句，每句至少停留 thoughtDwell。
    @State private var shownThought = ""
    @State private var shownThoughtAt: ContinuousClock.Instant?
    @Environment(\.palette) private var palette
    @Environment(\.pauseFollowing) private var pauseFollowing

    private static let thoughtDwell: TimeInterval = 1.5

    private var calls: [Transcript.ToolCall] {
        steps.compactMap { if case .tool(let call) = $0 { call } else { nil } }
    }

    private var runningCall: Transcript.ToolCall? {
        liveReasoning?.isEmpty == false ? nil : calls.last(where: \.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                // 亲手展开收起时不跟随到底：点的这一行留在原位，内容往下长或往上收
                pauseFollowing(expanded)
                withAnimation(.smooth(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    icon
                    label
                        .id(labelKey)
                        // 整行翻过去：位移等于行高，加上外面的裁切，新旧两句任何一帧都不叠在同一处
                        .transition(.asymmetric(
                            insertion: .offset(y: 24),
                            removal: .offset(y: -24)
                        ))
                        .lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.ink4)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
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
            .animation(.smooth(duration: 0.25), value: labelKey)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .task(id: latestThought) { await showThought(latestThought) }
            .accessibilityValue(expanded ? "已展开" : "已收起")

            Reveal(open: expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(steps) { step in ProcessStepRow(step: step, time: times[step.id]) }
                    if let liveReasoning, !liveReasoning.isEmpty {
                        ProcessStepRow(step: .reasoning(id: "live", text: liveReasoning), time: nil, live: true)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(palette.cardStroke).frame(width: 1) }
                .padding(.leading, 4).padding(.top, 4).padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .westieToggleProcess)) { note in
            guard note.object == nil || note.object as? String == steps.first?.id else { return }
            trace("toggle process \(steps.first?.id ?? "")")
            pauseFollowing(expanded)
            withAnimation(.smooth(duration: 0.22)) { expanded.toggle() }
        }
        .onGeometryChange(for: ProcessRowTrace.self) { ProcessRowTrace(id: steps.first?.id ?? "", y: $0.frame(in: .global).minY) } action: { old, new in
            trace("process \(new.id) minY \(old.y) -> \(new.y)")
        }
        #endif
    }

    /// 完成后是工具箱（只有思考时是灯泡）；运行中换成当前一步的图标并轻轻呼吸。
    @ViewBuilder private var icon: some View {
        let name: String = if active {
            runningCall.map { ProcessView.symbol($0.kind) } ?? "lightbulb"
        } else {
            calls.isEmpty ? "lightbulb" : "wrench.adjustable"
        }
        Image(systemName: name)
            .font(.system(size: 11))
            .frame(width: 14, height: 14)
            .symbolEffect(.pulse, options: .repeating, isActive: active)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityHidden(true)
    }

    private var labelKey: String {
        guard active else { return "done" }
        if let call = runningCall { return call.id }
        return "thinking-\(shownThought)"
    }

    /// 流式思考里最近一句写完的话；正在流出的半句不算。
    private var latestThought: String {
        ThoughtSentence.lastComplete(in: liveReasoning ?? "") ?? ""
    }

    /// task 随句子和视图生命周期取消；到期前的新句会替换旧任务，中间的略过。
    private func showThought(_ sentence: String) async {
        guard sentence != shownThought else { return }
        if let shownThoughtAt {
            let deadline = shownThoughtAt.advanced(by: .seconds(Self.thoughtDwell))
            do { try await ContinuousClock().sleep(until: deadline) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        shownThought = sentence
        shownThoughtAt = .now
        #if DEBUG
        trace("thought shown chars=\(sentence.count)")
        #endif
    }

    @ViewBuilder private var label: some View {
        if active, let call = runningCall {
            Text(call.stepText).foregroundStyle(palette.ink2)
        } else if active {
            Text(shownThought.isEmpty ? "思考中…" : shownThought)
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
            case .ask: "提问 \(n) 次"
            case .other: "调用 \(n) 个工具"
            }
        }
        var text = Text(parts.isEmpty ? "思考过程" : parts.joined(separator: "，"))
        let fails = calls.filter(\.isError).count
        if fails > 0 { text = text + Text(" · ") + Text("\(fails) 条失败").foregroundStyle(palette.bad) }
        if let duration, let formatted = Self.format(duration) {
            text = text + Text(" · \(formatted)").foregroundStyle(palette.ink4)
        }
        return text
    }

    static func format(_ duration: TimeInterval) -> String? {
        let seconds = Int(duration.rounded())
        guard seconds >= 1 else { return nil }
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds < 3600 { return seconds % 60 == 0 ? "\(seconds / 60) 分" : "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分"
    }

    static func symbol(_ kind: Transcript.ToolCall.Kind) -> String {
        switch kind {
        case .read: "doc.text"
        case .edit: "pencil"
        case .run: "apple.terminal"
        case .search: "magnifyingglass"
        case .web: "globe"
        case .ask: "questionmark.bubble"
        case .other: "wrench.and.screwdriver"
        }
    }

    static func verb(_ kind: Transcript.ToolCall.Kind) -> String {
        switch kind {
        case .read: "读取"
        case .edit: "修改"
        case .run: "运行"
        case .search: "搜索"
        case .web: "打开"
        case .ask: "提问"
        case .other: "调用"
        }
    }
}

/// 展开后的一步：图标 + 一行描述，悬停时右侧出现时间和箭头，点开看输出或完整的思考。
private struct ProcessStepRow: View {
    let step: Transcript.Item
    let time: Date?
    var live = false
    @State private var open = false
    @State private var hovering = false
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography
    @Environment(\.pauseFollowing) private var pauseFollowing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                pauseFollowing(open)
                withAnimation(.smooth(duration: 0.22)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(call?.isError == true ? palette.bad : palette.ink4)
                        .frame(width: 14, height: 14)
                        .accessibilityHidden(true)
                    Text(line).foregroundStyle(lineColor).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if running || live {
                        ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                    } else {
                        HStack(spacing: 6) {
                            if let time { Text(time, format: .dateTime.hour().minute()).monospacedDigit() }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .semibold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                        .foregroundStyle(palette.ink4)
                        .opacity(hovering || open ? 1 : 0)
                    }
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
            .animation(.easeOut(duration: 0.15), value: hovering)
            .accessibilityLabel("\(verb)：\(line)")

            Reveal(open: open) { detail }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .westieToggleStep)) { note in
            guard note.object as? String == step.id else { return }
            trace("toggle step \(step.id)")
            pauseFollowing(open)
            withAnimation(.smooth(duration: 0.22)) { open.toggle() }
        }
        .onGeometryChange(for: ProcessRowTrace.self) { ProcessRowTrace(id: step.id, y: $0.frame(in: .global).minY) } action: { old, new in
            trace("step \(new.id) minY \(old.y) -> \(new.y)")
        }
        #endif
    }

    private var call: Transcript.ToolCall? {
        if case .tool(let call) = step { call } else { nil }
    }

    private var running: Bool { call?.isRunning ?? false }

    private var symbol: String { call.map { ProcessView.symbol($0.kind) } ?? "lightbulb" }

    private var verb: String { call.map { ProcessView.verb($0.kind) } ?? "思考" }

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
                .padding(.leading, 22).padding(.top, 2).padding(.bottom, 6)
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
                .padding(.leading, 22).padding(.top, 2).padding(.bottom, 8)
        }
    }
}

/// 展开收起：高度从 0 长到自然高度、往下推开后面的内容，不叠在别的内容上。
/// 内容第一次打开前不挂载；挂上后先排一帧拿到高度，再在同一个动画事务里展开，下方内容一起平滑让位。
struct Reveal<Content: View>: View {
    let open: Bool
    @ViewBuilder let content: Content
    @State private var mounted = false
    @State private var shown = false

    var body: some View {
        // 外层始终存在（空时零高度），onChange 才一定挂得上
        VStack(alignment: .leading, spacing: 0) {
            if mounted {
                content
                    .frame(height: shown ? nil : 0, alignment: .top)
                    .clipped()
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
        .onChange(of: open, initial: true) { _, open in
            guard open != shown else { return }
            let transaction = Transaction(animation: .smooth(duration: 0.22))
            if open, !mounted {
                mounted = true
                DispatchQueue.main.async { withTransaction(transaction) { shown = true } }
            } else {
                withTransaction(transaction) { shown = open }
            }
        }
    }
}

private struct PauseFollowingKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable (_ collapsing: Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    /// 用户亲手展开或收起时调用：这次变化不跟随滚到底；收起时还要在底部垫空白，免得滚动位置被回收。
    var pauseFollowing: @MainActor @Sendable (_ collapsing: Bool) -> Void {
        get { self[PauseFollowingKey.self] }
        set { self[PauseFollowingKey.self] = newValue }
    }
}

#if DEBUG
extension Notification.Name {
    /// 自动化 `process`：像点了一下那样切换所有过程块的展开。
    static let westieToggleProcess = Notification.Name("westieToggleProcess")
    /// 自动化 `scroll:<y>`：对话滚到指定偏移，像用户翻到那里。
    static let westieScrollTo = Notification.Name("westieScrollTo")
    static let westieToggleStep = Notification.Name("westieToggleStep")
}

/// 排查布局跳动：WESTIE_TRACE=<文件> 时逐行记下位置变化。
func trace(_ line: @autoclosure () -> String) {
    guard let path = ProcessInfo.processInfo.environment["WESTIE_TRACE"] else { return }
    let data = Data("\(String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))) \(line())\n".utf8)
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile(); handle.write(data); try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
#endif

#if DEBUG
private struct ProcessRowTrace: Equatable {
    var id: String
    var y: CGFloat
}
#endif
