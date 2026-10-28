import SwiftUI
import WestieKit

struct RootView: View {
    @Bindable var model: AppModel
    let layout: PanelLayout

    var body: some View {
        Group {
            if model.phase == .ready {
                Workbench(layout: layout, model: model)
            } else {
                status
            }
        }
        .overlay(alignment: .top) { errorBanner }
        .navigationTitle(layout.focusedSessionId.flatMap { model.sessions[$0]?.displayTitle } ?? "Westie")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                toggle(.primary, symbol: "sidebar.left")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                toggle(.top, symbol: "rectangle.topthird.inset.filled")
                toggle(.bottom, symbol: "rectangle.bottomthird.inset.filled")
                toggle(.secondary, symbol: "sidebar.right")
            }
        }
        // 侧栏选中、新建会话 → 在面板里打开；聚焦的对话窗口变了 → 侧栏跟着高亮。
        .onChange(of: model.selectedSessionId) { _, id in
            if let id { layout.openConversation(id) }
        }
        .onChange(of: layout.focusedSessionId, initial: true) { _, id in
            if let id, id != model.selectedSessionId { model.selectedSessionId = id }
        }
        .onChange(of: layout.visibleSessionIds, initial: true) { _, ids in
            model.retainConversations(ids)
        }
    }

    private func toggle(_ panel: PanelID, symbol: String) -> some View {
        Button(panel.title, systemImage: symbol) { layout.toggle(panel) }
            .help("显示或收起\(panel.title)")
            .disabled(!layout.canToggle(panel))
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .starting, .ready:
            ProgressView("正在启动内核…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .waitingForDSH:
            ContentUnavailableView {
                Label("DeepSeek Harness 正在运行", systemImage: "pause.circle")
            } description: {
                Text("Westie 和 DeepSeek Harness 共用 ~/.dsh 里的会话与工作区，同时运行会互相覆盖。退出 DeepSeek Harness 后，Westie 会自动继续。")
            }
        case .reconnecting:
            ProgressView("正在重新连接内核…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("内核不可用", systemImage: "exclamationmark.triangle", description: Text(message))
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
