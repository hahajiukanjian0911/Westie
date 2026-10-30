import SwiftUI
import Textual
import WestieKit

struct ConversationView: View {
    @Environment(\.palette) private var palette
    @Environment(\.typography) private var typography
    let model: AppModel
    let conversation: ConversationModel
    /// 在当前窗口换成另一个会话（子 Agent 会话底部「回到父会话」用）。
    var openSession: (String) -> Void = { _ in }
    /// 滚动位置的唯一协调者（ConversationScroll.swift）：跟随底部、发出时顶到上方、点开收起原地不动都在那里。
    @State private var scroller = ConversationScroller()
    @State private var showsBackToBottom = false
    /// 原地等候（设计稿 2026-10-29-loading v1 方向 A）：200ms 还没到才出占位条；到了只淡入内容。
    @State private var placeholderShown = false
    @State private var revealed = false

    private var running: Bool {
        conversation.running || model.sessions[conversation.sessionId]?.running == true
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

    private var hostedChunks: [ConversationChunk<ConversationHostedContent>] {
        var groups: [(String, [ConversationRow])] = []
        for row in conversation.rows {
            if case .item(.user) = row.content.block {
                groups.append((row.id, [row]))
            } else if groups.isEmpty {
                groups.append(("prefix", [row]))
            } else {
                groups[groups.count - 1].1.append(row)
            }
        }
        if groups.isEmpty { groups.append(("prefix", [])) }
        func content(_ rows: [ConversationRow], tail: Bool, earlier: Bool = false) -> ConversationHostedContent {
            .init(model: model, conversation: conversation, scroller: scroller, rows: rows, tail: tail, earlier: earlier,
                palette: palette, typography: typography, themeIndex: model.appearance.themeIndex)
        }
        var chunks = groups.enumerated().map { index, group in
            ConversationChunk(id: group.0, content: content(group.1, tail: index == groups.count - 1))
        }
        if conversation.hasEarlierHistory {
            chunks.insert(.init(id: "earlier", content: content([], tail: false, earlier: true)), at: 0)
        }
        return chunks
    }

    var body: some View {
        let _ = PerfTrace.count("conversation_body")
        VStack(spacing: 0) {
            ConversationScroll(
                scroller: scroller,
                chunks: hostedChunks,
                firstSeq: conversation.firstSeq, lastUserId: conversation.lastUserId,
                columnWidth: typography.chatColumnWidth,
                loaded: !conversation.isLoading,
                onReady: {
                    placeholderShown = false
                    withAnimation(.easeOut(duration: 0.18)) { revealed = true }
                    scroller.refreshMetrics()
                }
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
            .onChange(of: conversation.lastItem?.id) {
                // 自己发出新消息：这条消息顶到上方，之后回复长过一屏再跟随。看末条换没换，不看条数：往前翻页只在前面加
                if case .user(let id, _) = conversation.lastItem, revealed {
                    scroller.sent(id)
                }
            }
            // 保持宿主正常排版与绘制；由独立遮盖挡住尚未提交的首开布局。
            .overlay { if !revealed { palette.card.accessibilityHidden(true).transition(.opacity) } }
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
                if !revealed, placeholderShown {
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
                } else if conversation.rows.isEmpty, conversation.live == nil, !running {
                    Text("还没有消息").uiFont(10).foregroundStyle(palette.ink4)
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(200))
                if !revealed { placeholderShown = true }
            }
            .onChange(of: conversation.isLoading, initial: true) { _, loading in
                if !loading { scroller.refreshMetrics() }
            }

            Group {
                if let parentId = conversation.parentSessionId {
                    ReadOnlyBar(parentTitle: model.sessions[parentId]?.displayTitle ?? "父会话") { openSession(parentId) }
                } else {
                    ComposerView(model: model, conversation: conversation, running: running)
                }
            }
                .frame(maxWidth: typography.chatColumnWidth)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
    }
}

/// 子 Agent 会话不能直接发消息：输入框换成一行说明和回到父会话的按钮。
private struct ReadOnlyBar: View {
    let parentTitle: String
    let back: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Text("子代理的会话只能查看").foregroundStyle(palette.ink4)
            Button(action: back) {
                Text("回到「\(parentTitle)」").lineLimit(1).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .uiFont(12.5)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.ink5.opacity(0.5), lineWidth: 0.5) }
    }
}

/// 宿主只在会话、显隐或外观改变时替换 rootView；模型由内部观察边界直接订阅。
private struct ConversationHostedContent: View, Equatable {
    let model: AppModel
    let conversation: ConversationModel
    let scroller: ConversationScroller
    let rows: [ConversationRow]
    let tail: Bool
    let earlier: Bool
    let palette: Palette
    let typography: Typography
    let themeIndex: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.conversation === rhs.conversation && lhs.scroller === rhs.scroller
            && lhs.rows.map(ObjectIdentifier.init) == rhs.rows.map(ObjectIdentifier.init)
            && lhs.tail == rhs.tail && lhs.earlier == rhs.earlier
            && lhs.palette.dark == rhs.palette.dark
            && lhs.typography == rhs.typography && lhs.themeIndex == rhs.themeIndex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if earlier {
                EarlierHistoryRow(conversation: conversation) { Task { await conversation.loadEarlier() } }
            } else {
                ForEach(rows) { row in
                    ConversationBlockView(row: row, model: model, conversation: conversation)
                        .anchorPreference(key: ConversationChunkRows.self, value: .bounds) { [row.id: $0] }
                }
                if tail { ConversationTail(model: model, conversation: conversation) }
            }
        }
            .backgroundPreferenceValue(TextualLayoutReadyKey.self) { ready in
                Color.clear.preference(key: ConversationChunkReady.self, value: ready)
            }
            .environment(\.palette, palette)
            .environment(\.typography, typography)
            .environment(\.pauseFollowing) { [scroller] _ in scroller.hold() }
            .font(typography.ui(13))
            .foregroundStyle(palette.ink)
            .tint(palette.accent)
    }
}

private struct ConversationBlockView: View {
    let row: ConversationRow
    let model: AppModel
    let conversation: ConversationModel

    var body: some View {
        let _ = PerfTrace.count("conversation_block_body")
        let content = row.content
        switch content.block {
        case .item(let item):
            TranscriptItemView(item: item)
        case .process(_, let steps):
            ConversationProcess(steps: steps, times: content.times, duration: content.duration,
                                trailing: content.trailing, model: model, conversation: conversation)
        }
    }
}

private struct ConversationProcess: View {
    let steps: [Transcript.Item]
    let times: [String: Date]
    let duration: TimeInterval?
    let trailing: Bool
    let model: AppModel
    let conversation: ConversationModel

    var body: some View {
        let live = trailing ? conversation.live : nil
        let active = trailing && (conversation.running || model.sessions[conversation.sessionId]?.running == true)
        ProcessView(steps: steps, liveReasoning: live?.reasoning,
                    active: active && live?.text.isEmpty != false, duration: duration, times: times)
    }
}

private struct ConversationTail: View {
    let model: AppModel
    let conversation: ConversationModel

    var body: some View {
        let approvals = model.approvals.filter { $0.sessionId == conversation.sessionId }
        let questions = model.questions.filter { $0.sessionId == conversation.sessionId }
        let running = conversation.running || model.sessions[conversation.sessionId]?.running == true
        if let live = conversation.live {
            LiveMessageView(live: live)
        } else if running, approvals.isEmpty, questions.isEmpty, conversation.rows.last?.isProcess != true {
            ProgressView().controlSize(.small).padding(.leading, 2)
        }
        ForEach(approvals) { approval in
            ApprovalCard(approval: approval) { allow in Task { await model.answer(approval, allow: allow) } }
        }
        ForEach(questions) { question in
            QuestionCard(question: question) { selections, custom in
                Task { await model.answer(question, selections: selections, custom: custom) }
            }
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
