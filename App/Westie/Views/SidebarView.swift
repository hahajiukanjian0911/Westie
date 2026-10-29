import AppKit
import SwiftUI
import WestieKit

/// 会话列表窗口：直接坐在外框上，按工作区分组（沿用主窗口 v7 侧栏的行样式）。
struct SidebarView: View {
    @Bindable var model: AppModel
    let layout: PanelLayout
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            sessionList
            SettingsEntry(selected: settingsFocused) { layout.showSettings() }
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    /// 设置卡片正聚焦时，入口跟会话行一样高亮。
    private var settingsFocused: Bool {
        layout.focusedWindowId.flatMap { layout.locate($0) }?.window.content == .settings
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.board.ordered) { workspace in
                    WorkspaceHeader(title: workspace.title) {
                        Task { await model.newSession(in: workspace) }
                    }
                    ForEach(model.sessions(in: workspace)) { session in
                        SessionRow(
                            session: session,
                            pending: model.pendingCount(for: session.id),
                            selected: session.id == model.selectedSessionId
                        ) {
                            model.selectedSessionId = session.id
                            layout.openConversation(session.id)
                        }
                        .contextMenu {
                            Button("在新窗口打开") { layout.openConversation(session.id, mode: .newWindow) }
                            Button("并排打开") { layout.openConversation(session.id, mode: .sideBySide) }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
    }

    static func chooseFolder(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "添加工作区"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addWorkspace(path: url.path(percentEncoded: false)) }
    }
}

/// 分组标题：工作区名，悬停时右侧出现新会话按钮。
private struct WorkspaceHeader: View {
    let title: String
    let newSession: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
            Spacer()
            Button("新会话", systemImage: "plus", action: newSession)
                .labelStyle(.iconOnly)
                .buttonStyle(IconButtonStyle())
                .help("在 \(title) 中新建会话")
                .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, 8)
        .frame(height: 28)
        .padding(.top, 12)
        .onHover { hovering = $0 }
    }
}

/// 侧栏底部的设置入口（设计稿 2026-10-29-settings v1 方向 B）。
private struct SettingsEntry: View {
    let selected: Bool
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape").font(.system(size: 13))
                Text("设置")
                Spacer(minLength: 0)
            }
            .font(.system(size: 13))
            .foregroundStyle(selected || hovering ? palette.ink : palette.ink2)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: Metrics.rowRadius)
                    .fill(selected ? palette.rowOn : hovering ? palette.rowHover : .clear)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(palette.rowOnStroke, lineWidth: 0.5)
                        }
                    }
                    .shadow(color: selected ? palette.cardShadowNear : .clear, radius: 1, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("设置（⌘,）")
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    let pending: Int
    let selected: Bool
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(session.displayTitle)
                    .lineLimit(1)
                    .foregroundStyle(selected || hovering ? palette.ink : session.blank ? palette.ink3 : palette.ink2)
                Spacer(minLength: 4)
                if pending > 0 {
                    Circle().fill(palette.warn).frame(width: 6, height: 6)
                        .help("等待你处理")
                } else if session.running {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: Metrics.rowRadius)
                    .fill(selected ? palette.rowOn : hovering ? palette.rowHover : .clear)
                    .overlay {
                        if selected {
                            RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(palette.rowOnStroke, lineWidth: 0.5)
                        }
                    }
                    .shadow(color: selected ? palette.cardShadowNear : .clear, radius: 1, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
