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

    private func endsWithProcess(_ blocks: [Transcript.Block]) -> Bool {
        if case .process = blocks.last { true } else { false }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.hasEarlierHistory {
                        EarlierHistoryRow(conversation: conversation, load: loadEarlier)
                    }
                    let blocks = displayBlocks
                    ForEach(blocks) { block in
                        switch block {
                        case .item(let item):
                            TranscriptItemView(item: item)
                        case .process(let id, let steps):
                            let trailing = id == blocks.last?.id
                            ProcessView(
                                steps: steps,
                                liveReasoning: trailing ? conversation.transcript.live?.reasoning : nil,
                                active: trailing && running && conversation.transcript.live?.text.isEmpty != false
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
                .opacity(revealed ? 1 : 0)
                .frame(maxWidth: typography.chatColumnWidth, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
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
                guard following, new > old else { return }
                // 回复生成中平滑跟上；空闲时（打开会话后逐段量出真实高度等）直接贴住底部，不出现滚动
                if running {
                    withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
                } else {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in
                offsetY = value
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .westieScrollTo)) { note in
                // 自动化 `scroll:<y>`：模拟用户翻到某处
                following = false
                scrollPosition.scrollTo(y: note.object as? CGFloat ?? 0)
            }
            #endif
            .environment(\.pauseFollowing) {
                // 位置原本钉在“底部”时，内容变高会把上面的内容往上推；改钉在当前偏移，展开的东西往下长
                following = false
                scrollPosition.scrollTo(y: offsetY)
            }
            .onChange(of: conversation.transcript.items.last?.id) {
                // 自己发出新消息时回到跟随。看末条换没换，不看条数：往前翻页只在前面加，末条不变
                if case .user = conversation.transcript.items.last { following = true }
            }
            .overlay(alignment: .bottom) {
                if conversation.isLoading, placeholderShown {
                    LoadingPlaceholder()
                        .frame(maxWidth: typography.chatColumnWidth, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
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
            }

            ComposerView(model: model, conversation: conversation, running: running)
                .frame(maxWidth: typography.chatColumnWidth)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
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
                Color.clear.frame(height: 1).onAppear(perform: load)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 20)
    }
}

/// 加载占位：一条用户消息、一段回复、两行工具，贴着底部，和真实排版的节奏对得上。
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
