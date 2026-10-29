import SwiftUI
import WestieKit

struct ConversationView: View {
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography
    let model: AppModel
    let conversation: ConversationModel
    /// 跟随到底：内容变高时平滑滚到底；用户往上翻就停，翻回底部再接着跟。
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var atBottom = true
    @State private var offsetY: CGFloat = 0
    /// 收起时在底部临时垫的空白：内容变短也不必回收滚动位置，点的那一行留在原处；往上翻时逐步收掉。
    @State private var slack: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var slackGeometry = SlackGeometry(offset: 0, viewport: 0, content: 0)
    /// 收起动画进行中不修剪空白：修剪若赶在收起生效前，位置照样会被回收。
    @State private var slackHeld = false
    /// 以每轮的用户消息为锚点（设计稿 2026-10-29-chat-scroll v1）：底部留白刚好够最后一条用户消息顶到上方，
    /// 回复越长留白越小；没用完就一直留着，直到下一条消息。
    @State private var lastUserY: CGFloat?
    @State private var contentEndY: CGFloat = 0
    /// 刚发出、还没滚到上方的那条消息。
    @State private var pendingAnchor: String?
    /// 原地等候（设计稿 2026-10-29-loading v1 方向 A）：200ms 还没到才出占位条；到了只淡入内容。
    @State private var placeholderShown = false
    @State private var revealed = false

    private var approvals: [PendingApproval] { model.approvals.filter { $0.sessionId == conversation.sessionId } }
    private var questions: [PendingQuestion] { model.questions.filter { $0.sessionId == conversation.sessionId } }
    private var running: Bool {
        conversation.transcript.running || model.sessions[conversation.sessionId]?.running == true
    }

    /// 往前加载一页，并把原来最上面那条留在原处，阅读位置不跳。
    private func loadEarlier() {
        let anchor = conversation.transcript.items.first?.id
        Task {
            // 还在跟随到底（刚打开、内容不满一屏）就留在底部；只有往上翻着读、且真的接上了记录时才钉住原位置。
            if await conversation.loadEarlier(), let anchor, !following { scrollPosition.scrollTo(id: anchor, anchor: .top) }
        }
    }

    /// 流式中的思考要归进最后一个过程块；前面没有过程块时先补一个空的，落盘后 id 不变。
    private var displayBlocks: [Transcript.Block] {
        var blocks = conversation.transcript.blocks
        if let live = conversation.transcript.live, !live.reasoning.isEmpty, !endsWithProcess(blocks) {
            blocks.append(.process(id: Transcript.processId(after: blocks.last), steps: []))
        }
        return blocks
    }

    private static let space = "conversation"
    /// 消息顶到上方时留的边距，和列表顶部留白一致。
    private static let anchorMargin: CGFloat = 16
    private static let bottomPadding: CGFloat = 24

    private var lastUserId: String? {
        conversation.transcript.items.last { if case .user = $0 { true } else { false } }?.id
    }

    /// 让最后一条用户消息能顶到窗口上方所需的底部留白。
    private var turnSpace: CGFloat {
        guard let lastUserY, viewportHeight > 0 else { return 0 }
        return max(0, viewportHeight - Self.anchorMargin - (contentEndY + Self.bottomPadding - lastUserY))
    }

    /// 可见内容（不含留白）底部离窗口底部还有多远：大于一点就给回到底部。
    private var distanceToEnd: CGFloat {
        let geometry = slackGeometry
        return geometry.content - turnSpace - slack - Self.bottomPadding - (geometry.offset + geometry.viewport)
    }

    /// 只留住让当前位置有效所需的那一截空白：看得见的部分；往上翻后就不需要了。
    private func trimSlack() {
        guard slack > 0, !slackHeld else { return }
        let geometry = slackGeometry
        let needed = max(0, geometry.offset + geometry.viewport - (geometry.content - slack))
        if needed < slack { slack = needed }
    }

    /// 翻到离顶部不到 400pt（或内容不满一屏）时往前加载一页。
    private func loadEarlierIfNearTop() {
        guard revealed, offsetY < 400, conversation.hasEarlierHistory, !conversation.isLoadingEarlier,
              conversation.earlierError == nil else { return }
        loadEarlier()
    }

    /// 刚发出的消息量到位置后，等留白排上再平滑滚到上方。
    private func anchorIfPending(_ id: String, y: CGFloat) {
        guard pendingAnchor == id else { return }
        DispatchQueue.main.async {
            guard pendingAnchor == id else { return }
            pendingAnchor = nil
            withAnimation(.smooth(duration: 0.35)) { scrollPosition.scrollTo(y: max(0, y - Self.anchorMargin)) }
        }
    }

    private func endsWithProcess(_ blocks: [Transcript.Block]) -> Bool {
        if case .process = blocks.last { true } else { false }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if conversation.hasEarlierHistory {
                        EarlierHistoryRow(conversation: conversation, load: loadEarlier)
                    }
                    let blocks = displayBlocks
                    let previous = Dictionary(zip(blocks.dropFirst().map(\.id), blocks.map(\.id)), uniquingKeysWith: { first, _ in first })
                    ForEach(blocks) { block in
                        switch block {
                        case .item(let item):
                            TranscriptItemView(item: item)
                                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { y in
                                    guard item.id == lastUserId else { return }
                                    lastUserY = y
                                    anchorIfPending(item.id, y: y)
                                }
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
                .scrollTargetLayout()
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).maxY } action: { contentEndY = $0 }
                .opacity(revealed ? 1 : 0)
                .frame(maxWidth: typography.chatColumnWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                // 留白只靠滚动给出：内容从上往下排，空白只在底部
                .padding(.bottom, Self.bottomPadding + turnSpace + slack)
                .frame(maxWidth: .infinity)
                .coordinateSpace(.named(Self.space))
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 24
            } action: { _, value in
                atBottom = value
            }
            .onScrollPhaseChange { old, new in
                // 用户一动手就停止跟随，松手停稳后按是否在底部决定恢复；程序滚动（.animating）不改变跟随状态
                if new == .interacting {
                    following = false
                } else if new == .idle, old == .interacting || old == .decelerating {
                    following = atBottom
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                loadEarlierIfNearTop()
                guard following, new > old, pendingAnchor == nil else { return }
                // 回复生成中：留白还在就不动，留白用完、回复长过一屏后才平滑跟上；
                // 空闲时（打开会话后逐段量出真实高度等）直接贴住底部，不出现滚动
                if running {
                    guard turnSpace == 0 else { return }
                    withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
                } else {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { old, value in
                offsetY = value
                loadEarlierIfNearTop()
                #if DEBUG
                trace("offset \(old) -> \(value)")
                #endif
            }
            #if DEBUG
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, value in
                trace("content \(old) -> \(value)")
            }
            #endif
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .westieScrollTo)) { note in
                // 自动化 `scroll:<y>`：模拟用户翻到某处
                following = false
                scrollPosition.scrollTo(y: note.object as? CGFloat ?? 0)
            }
            #endif
            .environment(\.pauseFollowing) { collapsing in
                // 位置原本钉在“底部”时，内容变高会把上面的内容往上推；改钉在当前偏移，展开的东西往下长
                following = false
                scrollPosition.scrollTo(y: offsetY)
                // 收起前先垫一屏空白，内容变短也不会回收滚动位置。展开收起动画进行中都不修剪：
                // 动画中间帧的内容高度还没到位，这时把空白收掉，位置照样会被回收
                if collapsing { slack += viewportHeight }
                slackHeld = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    slackHeld = false
                    trimSlack()
                }
            }
            .onScrollGeometryChange(for: SlackGeometry.self) { geometry in
                SlackGeometry(offset: geometry.contentOffset.y, viewport: geometry.containerSize.height, content: geometry.contentSize.height)
            } action: { _, geometry in
                viewportHeight = geometry.viewport
                slackGeometry = geometry
                trimSlack()
            }
            .onChange(of: conversation.transcript.items.last?.id) {
                // 自己发出新消息：这条消息顶到上方，之后回复长过一屏再跟随。看末条换没换，不看条数：往前翻页只在前面加
                if case .user(let id, _) = conversation.transcript.items.last, revealed {
                    following = true
                    slack = 0
                    pendingAnchor = id
                }
            }
            .overlay(alignment: .bottom) {
                if revealed, distanceToEnd > 40 {
                    Button {
                        following = true
                        withAnimation(.smooth(duration: 0.35)) { scrollPosition.scrollTo(edge: .bottom) }
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
                loadEarlierIfNearTop()
            }

            ComposerView(model: model, conversation: conversation, running: running)
                .frame(maxWidth: typography.chatColumnWidth)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct SlackGeometry: Equatable {
    var offset, viewport, content: CGFloat
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
