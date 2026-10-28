import SwiftUI
import WestieKit

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .overlay(alignment: .top) { errorBanner }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.phase {
        case .starting:
            ProgressView("正在启动内核…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .reconnecting:
            ProgressView("正在重新连接内核…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("内核不可用", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            if let conversation = model.conversation {
                ConversationView(model: model, conversation: conversation)
                    .id(conversation.sessionId)
            } else if model.board.ordered.isEmpty {
                ContentUnavailableView {
                    Label("还没有工作区", systemImage: "folder")
                } description: {
                    Text("打开一个文件夹，在里面开始会话。")
                } actions: {
                    Button("打开文件夹…") { SidebarView.chooseFolder(model: model) }
                }
            } else {
                ContentUnavailableView("选择或新建一个会话", systemImage: "bubble.left.and.bubble.right")
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = model.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(message).lineLimit(2)
                Button("关闭", systemImage: "xmark") { model.dismissError() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .padding(.top, 8)
        }
    }
}
