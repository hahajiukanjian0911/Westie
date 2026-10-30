import SwiftUI
import WestieKit

/// ⌘N 弹出的新建会话面板（设计稿 2026-10-29-session-list v1）：先选在哪个工作区新建。
/// 最近用过的工作区在前，「无项目」在最后；⌘1–⌘9 直达，末尾是「添加工作区…」。
struct NewSessionPanel: View {
    let model: AppModel
    @Environment(\.palette) private var palette
    @State private var query = ""
    /// 选中项按工作区 id 记：后台有新活动让顺序变了，回车仍在原来选的工作区新建。
    @State private var selection: String?
    /// 打开时定下的顺序，面板开着期间不跟着后台活动重排。
    @State private var order: [String] = []
    @FocusState private var focused: Bool

    private enum Item: Identifiable {
        case workspace(Workspace)
        case add

        var id: String {
            switch self {
            case .workspace(let workspace): workspace.id
            case .add: "add"
            }
        }
    }

    private var items: [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let recent = model.workspacesByRecent
        let sorted = recent.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        let workspaces = sorted.filter {
            needle.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(needle) || $0.path.localizedCaseInsensitiveContains(needle)
        }
        return workspaces.map(Item.workspace) + [.add]
    }

    private var selectedIndex: Int {
        let list = items
        return list.firstIndex { $0.id == selection } ?? 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            (palette.dark ? Color.black.opacity(0.3) : Palette.oklch(0.3, 0.03, 75, 0.12))
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            panel
                .padding(.top, 96)
        }
        .onAppear {
            order = model.workspacesByRecent.map(\.id)
            focused = true
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").uiFont(14).foregroundStyle(palette.ink3)
                TextField("在哪个工作区新建会话？", text: $query)
                    .textFieldStyle(.plain)
                    .uiFont(15)
                    .focused($focused)
                    .onChange(of: query) { selection = nil }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.return) {
                        choose(items[selectedIndex])
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
                    .onKeyPress(phases: .down) { press in
                        guard press.modifiers == .command, let digit = Int(press.characters), (1...9).contains(digit) else { return .ignored }
                        let workspaces = items.compactMap { if case .workspace(let w) = $0 { w } else { nil } }
                        guard workspaces.indices.contains(digit - 1) else { return .handled }
                        choose(.workspace(workspaces[digit - 1]))
                        return .handled
                    }
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Rectangle().fill(palette.ink5.opacity(0.5)).frame(height: 0.5)
            Text("工作区")
                .uiFont(11)
                .foregroundStyle(palette.ink4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if case .add = item, index > 0 {
                                Rectangle().fill(palette.ink5.opacity(0.5)).frame(height: 0.5).padding(.horizontal, 10).padding(.vertical, 4)
                            }
                            row(item, index: index).id(item.id)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                // 方向键选到视野外时跟着滚过去
                .onChange(of: selection) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 560)
        .background(palette.box, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(palette.boxStroke, lineWidth: 0.5) }
        .shadow(color: palette.boxShadow, radius: 30, y: 12)
        .shadow(color: palette.boxShadow, radius: 6, y: 2)
    }

    @ViewBuilder
    private func row(_ item: Item, index: Int) -> some View {
        let selected = index == selectedIndex
        Button { choose(item) } label: {
            HStack(spacing: 10) {
                switch item {
                case .workspace(let workspace):
                    WorkspaceMark(workspace: workspace, size: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.displayTitle).uiFont(13.5).foregroundStyle(palette.ink)
                        if !workspace.isDefault {
                            Text(abbreviated(workspace.path)).uiFont(11.5).foregroundStyle(palette.ink4)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 8)
                    if query.isEmpty, index < 9 {
                        Text("⌘\(index + 1)").uiFont(12).foregroundStyle(palette.ink4)
                    }
                case .add:
                    Image(systemName: "plus").uiFont(13).foregroundStyle(palette.ink3).frame(width: 18, height: 18)
                    Text("添加工作区…").uiFont(13.5).foregroundStyle(palette.ink2)
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: 44)
            .background(selected ? (palette.dark ? Color.white.opacity(0.08) : palette.accent.opacity(0.1)) : .clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selection = item.id } }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        let list = items
        selection = list[(selectedIndex + delta + list.count) % list.count].id
        return .handled
    }

    private func choose(_ item: Item) {
        dismiss()
        switch item {
        case .workspace(let workspace):
            Task { await model.newSession(in: workspace) }
        case .add:
            // 等面板收起后再弹选文件夹窗口
            DispatchQueue.main.async { SidebarView.chooseFolder(model: model, thenNewSession: true) }
        }
    }

    private func dismiss() { model.showingNewSession = false }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        return path.hasPrefix(trimmed) ? "~" + path.dropFirst(trimmed.count) : path
    }
}
