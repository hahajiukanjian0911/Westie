import SwiftUI
import WestieKit

struct ConversationView: View {
    let model: AppModel
    let conversation: ConversationModel

    private var approvals: [PendingApproval] { model.approvals.filter { $0.sessionId == conversation.sessionId } }
    private var questions: [PendingQuestion] { model.questions.filter { $0.sessionId == conversation.sessionId } }
    private var running: Bool {
        conversation.transcript.running || model.sessions[conversation.sessionId]?.running == true
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if conversation.hasEarlierHistory {
                        Text("更早的消息暂未加载")
                            .font(.caption).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
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
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .overlay {
                if conversation.isLoading {
                    ProgressView()
                } else if let error = conversation.followError {
                    ContentUnavailableView("无法打开会话", systemImage: "exclamationmark.triangle", description: Text(error))
                }
            }

            ComposerView(model: model, conversation: conversation, running: running)
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
        }
        .navigationTitle(model.sessions[conversation.sessionId]?.displayTitle ?? "会话")
    }
}
