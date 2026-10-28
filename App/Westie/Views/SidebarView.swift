import AppKit
import SwiftUI
import WestieKit

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.selectedSessionId) {
            ForEach(model.board.ordered) { workspace in
                Section {
                    ForEach(model.sessions(in: workspace)) { session in
                        SessionRow(session: session, pending: model.pendingCount(for: session.id))
                            .tag(session.id)
                    }
                } header: {
                    HStack {
                        Text(workspace.title)
                        Spacer()
                        Button("新会话", systemImage: "plus") {
                            Task { await model.newSession(in: workspace) }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("在 \(workspace.title) 中新建会话")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem {
                Button("打开文件夹", systemImage: "folder.badge.plus") { Self.chooseFolder(model: model) }
                    .help("添加工作区")
                    .disabled(model.phase != .ready)
            }
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

private struct SessionRow: View {
    let session: SessionSummary
    let pending: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(session.displayTitle)
                .lineLimit(1)
                .foregroundStyle(session.blank ? .secondary : .primary)
            Spacer(minLength: 4)
            if pending > 0 {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                    .help("等待你处理")
            } else if session.running {
                ProgressView().controlSize(.mini)
            }
        }
    }
}
