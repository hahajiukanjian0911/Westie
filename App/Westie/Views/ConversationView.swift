import SwiftUI
import WestieKit

struct ConversationView: View {
    let model: AppModel
    let conversation: ConversationModel
    /// 跟随到底：内容变高时平滑滚到底；用户往上翻就停，翻回底部再接着跟。
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var following = true
    @State private var atBottom = true

    private var approvals: [PendingApproval] { model.approvals.filter { $0.sessionId == conversation.sessionId } }
    private var questions: [PendingQuestion] { model.questions.filter { $0.sessionId == conversation.sessionId } }
    private var running: Bool {
        conversation.transcript.running || model.sessions[conversation.sessionId]?.running == true
    }

    /// 往前加载一页，并把原来最上面那条留在原处，阅读位置不跳。
    private func loadEarlier() {
        let anchor = conversation.transcript.items.first?.id
        Task {
            await conversation.loadEarlier()
            // 还在跟随到底（刚打开、内容不满一屏）就留在底部；只有往上翻着读时才钉住原位置。
            if let anchor, !following { scrollPosition.scrollTo(id: anchor, anchor: .top) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if conversation.hasEarlierHistory {
                        EarlierHistoryRow(conversation: conversation, load: loadEarlier)
                    }
                    ForEach(conversation.transcript.items) { item in
                        TranscriptItemView(item: item)
                    }
                    if let live = conversation.transcript.live {
                        LiveMessageView(live: live)
                    } else if running, approvals.isEmpty, questions.isEmpty {
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
                .frame(maxWidth: 760, alignment: .leading)
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
                withAnimation(.easeOut(duration: 0.3)) { scrollPosition.scrollTo(edge: .bottom) }
            }
            .onChange(of: conversation.transcript.items.count) {
                // 自己发出新消息时回到跟随
                if case .user = conversation.transcript.items.last { following = true }
            }
            .overlay {
                if conversation.isLoading {
                    ProgressView()
                } else if let error = conversation.followError {
                    ContentUnavailableView("无法打开会话", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            }

            ComposerView(model: model, conversation: conversation, running: running)
                .frame(maxWidth: 760)
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
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Color.clear.frame(height: 1).onAppear(perform: load)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 20)
    }
}
