import SwiftUI
import WestieKit

struct ConversationView: View {
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography
    let model: AppModel
    let conversation: ConversationModel
    /// 滚动位置的唯一协调者（ConversationScroll.swift）：跟随底部、发出时顶到上方、点开收起原地不动都在那里。
    @State private var scroller = ConversationScroller()
    @State private var showsBackToBottom = false
    /// 原地等候（设计稿 2026-10-29-loading v1 方向 A）：200ms 还没到才出占位条；到了只淡入内容。
    @State private var placeholderShown = false
    @State private var revealed = false

    private var running: Bool {
        conversation.transcript.running || model.sessions[conversation.sessionId]?.running == true
    }

    /// 往前加载一页；插入的高度由 scroller 补到偏移上，阅读位置不跳。
    private func loadEarlier() {
        Task { await conversation.loadEarlier() }
    }

    /// 翻到离顶部不到 400pt（或内容不满一屏）时往前加载一页。
    private func loadEarlierIfNearTop(offset: CGFloat) {
        guard revealed, scroller.hasMeasuredHistory, offset < 400, conversation.hasEarlierHistory, !conversation.isLoadingEarlier,
              conversation.earlierError == nil else { return }
        loadEarlier()
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationScroll(
                scroller: scroller,
                content: ConversationContent(model: model, conversation: conversation, scroller: scroller, running: running, loadEarlier: loadEarlier)
                    .opacity(revealed ? 1 : 0)
                    .environment(\.palette, palette)
                    .environment(\.typography, typography)
                    .environment(\.pauseFollowing) { [scroller] _ in scroller.hold() }
                    .font(typography.ui(13))
                    .foregroundStyle(palette.ink)
                    .tint(palette.accent)
            )
            .onAppear {
                scroller.onMetrics = { metrics in
                    let shows = revealed && metrics.distanceToEnd > 40
                    if shows != showsBackToBottom { showsBackToBottom = shows }
                    loadEarlierIfNearTop(offset: metrics.offset)
                }
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .westieScrollTo)) { note in
                // 自动化 `scroll:<y>`：模拟用户翻到某处
                scroller.userScroll(to: note.object as? CGFloat ?? 0)
            }
            #endif
            .onChange(of: conversation.transcript.items.last?.id) {
                // 自己发出新消息：这条消息顶到上方，之后回复长过一屏再跟随。看末条换没换，不看条数：往前翻页只在前面加
                if case .user(let id, _) = conversation.transcript.items.last, revealed {
                    scroller.sent(id)
                }
            }
            .overlay(alignment: .bottom) {
                if showsBackToBottom {
                    Button {
                        scroller.scrollToEnd()
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.ink3)
                            .frame(width: 28, height: 28)
                            .background(palette.box, in: .circle)
                            .overlay(Circle().strokeBorder(palette.boxStroke, lineWidth: 0.5))
                            .shadow(color: palette.boxShadow, radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到底部")
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)).animation(.easeOut(duration: 0.18)))
                }
            }
            .overlay(alignment: .top) {
                if conversation.isLoading, placeholderShown {
                    // 内容从上往下排，占位条也从上方开始，到了直接换成内容
                    LoadingPlaceholder()
                        .frame(maxWidth: typography.chatColumnWidth, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        // 出现时淡入；内容到了同一帧直接移除，不和内容交叉淡变
                        .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.18)), removal: .identity))
                }
            }
            .overlay {
                if conversation.isLoading {
                } else if let error = conversation.followError {
                    ContentUnavailableView("无法打开会话", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if conversation.transcript.items.isEmpty, conversation.transcript.live == nil, !running {
                    Text("还没有消息").uiFont(10).foregroundStyle(palette.ink4)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(200))
                if conversation.isLoading { placeholderShown = true }
            }
            .onChange(of: conversation.isLoading, initial: true) { _, loading in
                guard !loading, !revealed else { return }
                // 占位条与内容同一帧换掉，不做两层交叉淡变；只给内容一个淡入
                placeholderShown = false
                withAnimation(.easeOut(duration: 0.18)) { revealed = true }
                scroller.refreshMetrics()
            }

            ComposerView(model: model, conversation: conversation, running: running)
                .frame(maxWidth: typography.chatColumnWidth)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 滚动区里的全部内容：从上往下排，量出内容底部和最后一条用户消息的位置交给 scroller。
private struct ConversationContent: View {
    @Environment(\.typography) private var typography
    let model: AppModel
    let conversation: ConversationModel
    let scroller: ConversationScroller
    let running: Bool
    let loadEarlier: () -> Void

    private static let space = "conversation"

    private var approvals: [PendingApproval] { model.approvals.filter { $0.sessionId == conversation.sessionId } }
    private var questions: [PendingQuestion] { model.questions.filter { $0.sessionId == conversation.sessionId } }

    private var lastUserId: String? {
        conversation.transcript.items.last { if case .user = $0 { true } else { false } }?.id
    }

    /// 流式中的思考要归进最后一个过程块；前面没有过程块时先补一个空的，落盘后 id 不变。
    private var displayBlocks: [Transcript.Block] {
        var blocks = conversation.transcript.blocks
        if let live = conversation.transcript.live, !live.reasoning.isEmpty, !endsWithProcess(blocks) {
            blocks.append(.process(id: Transcript.processId(after: blocks.last), steps: []))
        }
        return blocks
    }

    private func endsWithProcess(_ blocks: [Transcript.Block]) -> Bool {
        if case .process = blocks.last { true } else { false }
    }

    var body: some View {
        TopAligned {
            column
        }
        .coordinateSpace(.named(Self.space))
    }

    private var column: some View {
        // 与本次渲染的行身份一同捕获，偏好回调执行时不读取可能已经更新的下一份 transcript。
        let blocks = displayBlocks
        let firstSeq = conversation.transcript.firstSeq
        let measuredLastUserId = lastUserId
        return VStack(alignment: .leading, spacing: 16) {
            if conversation.hasEarlierHistory {
                EarlierHistoryRow(conversation: conversation, load: loadEarlier)
            }
            let previous = Dictionary(zip(blocks.dropFirst().map(\.id), blocks.map(\.id)), uniquingKeysWith: { first, _ in first })
            ForEach(blocks) { block in
                Group {
                    switch block {
                    case .item(let item):
                        TranscriptItemView(item: item)
                    case .process(let id, let steps):
                        let trailing = id == blocks.last?.id
                        let transcript = conversation.transcript
                        let span = transcript.span(of: steps, after: previous[id])
                        ProcessView(
                            steps: steps,
                            liveReasoning: trailing ? transcript.live?.reasoning : nil,
                            active: trailing && running && transcript.live?.text.isEmpty != false,
                            duration: span.map { $0.end.timeIntervalSince($0.start) },
                            times: transcript.times
                        )
                    }
                }
                .anchorPreference(key: ConversationRowAnchors.self, value: .bounds) { [block.id: $0] }
            }
            if let live = conversation.transcript.live {
                LiveMessageView(live: live)
            } else if running, approvals.isEmpty, questions.isEmpty, !endsWithProcess(blocks) {
                ProgressView().controlSize(.small).padding(.leading, 2)
            }
            ForEach(approvals) { approval in
                ApprovalCard(approval: approval) { allow in
                    Task { await model.answer(approval, allow: allow) }
                }
            }
            ForEach(questions) { question in
                QuestionCard(question: question) { selections, custom in
                    Task { await model.answer(question, selections: selections, custom: custom) }
                }
            }
        }
        .backgroundPreferenceValue(ConversationRowAnchors.self) { anchors in
            GeometryReader { proxy in
                let origin = proxy.frame(in: .named(Self.space)).minY
                let measurement = ConversationGeometry(
                    end: origin + proxy.size.height,
                    firstSeq: firstSeq,
                    lastUserId: measuredLastUserId,
                    rows: anchors.mapValues { origin + proxy[$0].minY }
                )
                Color.clear.onChange(of: measurement, initial: true) { _, value in scroller.layoutChanged(value) }
            }
        }
        .frame(maxWidth: typography.chatColumnWidth, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }
}

private struct ConversationRowAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// 子视图按自身理想高度排、贴顶摆放。文档高度比内容晚一拍跟上时，多出来的部分往下伸，
/// 不像 fixedSize 那样把超出的内容居中（那会让整页先往上偏半截再回来）。
private struct TopAligned: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// 列表顶端：滚到这里就自动加载更早的消息；出错时给一个重试。
private struct EarlierHistoryRow: View {
    let conversation: ConversationModel
    let load: () -> Void

    var body: some View {
        Group {
            if conversation.isLoadingEarlier {
                ProgressView().controlSize(.small)
            } else if let error = conversation.earlierError {
                HStack(spacing: 6) {
                    Text("更早的消息加载失败：\(error)").lineLimit(1)
                    Button("重试", action: load).buttonStyle(.link)
                }
                .uiFont(10).foregroundStyle(.secondary)
            } else {
                // 何时加载由 ConversationView 按滚动位置决定：VStack 里的行一创建就会 onAppear
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 20)
    }
}

/// 加载占位：一条用户消息、一段回复、两行工具，从上方开始，和真实排版的节奏对得上。
private struct LoadingPlaceholder: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            bar(width: 220, height: 28, radius: 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([0.92, 0.84, 0.46], id: \.self) { fraction in
                        bar(width: geometry.size.width * fraction)
                    }
                }
            }
            .frame(height: 46)
            bar(width: 260)
            bar(width: 210)
        }
        .accessibilityHidden(true)
    }

    private func bar(width: CGFloat, height: CGFloat = 10, radius: CGFloat = 5) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(palette.placeholder).frame(width: width, height: height)
    }
}
