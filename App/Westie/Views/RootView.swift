import SwiftUI
import WestieKit

struct RootView: View {
    @Bindable var model: AppModel
    let layout: PanelLayout
    @Environment(\.colorScheme) private var colorScheme

    /// 外框先行（设计稿 2026-10-29-loading v1 方向 C）：内核没就绪时只有外框和状态；
    /// 就绪后侧栏和卡片一起升起。外框始终不动，只有 Workbench 做过渡。
    @State private var workbenchShown = false
    @State private var launchedAt = Date()

    var body: some View {
        ZStack {
            FrameBackground()
            if workbenchShown {
                Workbench(layout: layout, model: model)
                    .transition(.rise)
            } else {
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
            }
        }
        .onChange(of: model.phase == .ready, initial: true) { _, ready in
            // 0.4 秒内就绪就直接出现，不播
            let animate = ready && Date().timeIntervalSince(launchedAt) > 0.4
            withAnimation(animate ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.32) : nil) {
                workbenchShown = ready
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
            Text("Westie")
                .font(.system(size: 15, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(palette.ink3)
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

/// 卡片升起：从下方 8pt、略小一点淡入到原位。终点就是静止态，不留任何偏移。
private struct RiseModifier: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.985 + 0.015 * progress)
            .offset(y: 8 * (1 - progress))
    }
}

extension AnyTransition {
    static var rise: AnyTransition {
        .modifier(active: RiseModifier(progress: 0), identity: RiseModifier(progress: 1))
    }
}
