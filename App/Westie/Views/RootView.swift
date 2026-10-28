import SwiftUI
import WestieKit

struct RootView: View {
    @Bindable var model: AppModel
    let layout: PanelLayout
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if model.phase == .ready {
                Workbench(layout: layout, model: model)
            } else {
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .card(palette)
                    .padding(Metrics.gap)
                    .padding(.top, Metrics.lightsHeight - Metrics.gap)
                    .background { FrameBackground() }
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .overlay(alignment: .top) { errorBanner }
        .environment(\.palette, palette)
        .foregroundStyle(palette.ink)
        .tint(palette.accent)
        .navigationTitle(layout.focusedSessionId.flatMap { model.sessions[$0]?.displayTitle } ?? "Westie")
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

    private var palette: Palette { Palette(dark: colorScheme == .dark) }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .starting, .ready:
            ProgressView("正在启动内核…")
        case .waitingForDSH:
            ContentUnavailableView {
                Label("DeepSeek Harness 正在运行", systemImage: "pause.circle")
            } description: {
                Text("Westie 和 DeepSeek Harness 共用 ~/.dsh 里的会话与工作区，同时运行会互相覆盖。退出 DeepSeek Harness 后，Westie 会自动继续。")
            }
        case .reconnecting:
            ProgressView("正在重新连接内核…")
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
            .background(palette.box, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.boxStroke, lineWidth: 0.5))
            .shadow(color: palette.boxShadow, radius: 8, y: 2)
            .padding(.top, 12)
        }
    }
}
