import AppKit
import SwiftUI
import WestieKit

/// 会话列表窗口：直接坐在外框上（设计稿 2026-10-29-session-list v1）。
/// 进行中的会话不分组、按最近活动排成一列，工作区是每行的标识；闲置的沉到底部「归档」。
struct SidebarView: View {
    @Bindable var model: AppModel
    let layout: PanelLayout
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var archiveOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(text: $query)
                Button("新会话", systemImage: "square.and.pencil") { model.showingNewSession = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(IconButtonStyle())
                    .help("新会话（⌘N）")
            }
            .padding(.top, 2)
            .padding(.bottom, 10)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(spacing: 0) {
                    if query.isEmpty {
                        sessionList(now: context.date)
                        archive(now: context.date)
                    } else {
                        searchResults(now: context.date)
                    }
                }
            }
            SettingsEntry(selected: settingsFocused) { layout.showSettings() }
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
    }

    /// 设置卡片正聚焦时，入口跟会话行一样高亮。
    private var settingsFocused: Bool {
        layout.focusedWindowId.flatMap { layout.locate($0) }?.window.content == .settings
    }

    private func sessionList(now: Date) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.activeSessions) { session in
                        sessionRow(session, now: now).id(session.id)
                    }
                }
                .padding(.bottom, 8)
            }
            // 新建或从别处选中的会话滚进视野（新会话排在最上面）。
            .onChange(of: model.selectedSessionId) { _, id in
                guard let id, model.activeSessions.contains(where: { $0.id == id }) else { return }
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { proxy.scrollTo(id) }
            }
        }
        .scrollIndicators(.never)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSummary, now: Date) -> some View {
        let children = model.children(of: session.id)
        SessionRow(
            session: session,
            workspace: model.workspace(for: session),
            now: now,
            pending: model.pendingCount(for: session.id),
            selected: session.id == model.selectedSessionId,
            children: children.count,
            expanded: expanded.contains(session.id),
            open: { open(session.id) },
            archive: { Task { await model.archive(session.id) } },
            toggleChildren: {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.24)) {
                    if expanded.contains(session.id) { expanded.remove(session.id) } else { expanded.insert(session.id) }
                }
            }
        )
        .contextMenu { menu(for: session, archived: false) }
        if expanded.contains(session.id) {
            ForEach(children) { child in
                ChildRow(session: child, selected: child.id == model.selectedSessionId) { open(child.id) }
                    .contextMenu {
                        Button("在新窗口打开") { layout.openConversation(child.id, mode: .newWindow) }
                        Button("并排打开") { layout.openConversation(child.id, mode: .sideBySide) }
                    }
            }
        }
    }

    /// 底部「归档」：平时一行，展开后和上面的列表各占一半，行改成单行。
    private func archive(now: Date) -> some View {
        let archived = model.archivedSessions
        return VStack(spacing: 0) {
            Rectangle().fill(palette.ink5.opacity(0.5)).frame(height: 0.5).padding(.horizontal, 4)
            Button {
                withAnimation(reduceMotion ? nil : .spring(duration: 0.28)) { archiveOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("归档").foregroundStyle(palette.ink3)
                    Text("\(archived.count)").monospacedDigit().foregroundStyle(palette.ink4)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .uiFont(9, .semibold)
                        .foregroundStyle(palette.ink3)
                        .rotationEffect(.degrees(archiveOpen ? 180 : 0))
                }
                .uiFont(12)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if archiveOpen {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(archived) { session in
                            ArchivedRow(session: session, workspace: model.workspace(for: session), now: now,
                                        selected: session.id == model.selectedSessionId,
                                        open: { open(session.id) },
                                        restore: { Task { await model.unarchive(session.id) } })
                                .contextMenu { menu(for: session, archived: true) }
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .frame(maxHeight: archiveOpen ? .infinity : nil)
    }

    /// 搜索同时找进行中和已归档的会话，匹配标题或工作区名。
    private func searchResults(now: Date) -> some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        func matches(_ session: SessionSummary) -> Bool {
            session.displayTitle.localizedCaseInsensitiveContains(needle)
                || (model.workspace(for: session)?.displayTitle.localizedCaseInsensitiveContains(needle) ?? false)
        }
        let active = model.activeSessions.filter(matches)
        let archived = model.archivedSessions.filter(matches)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(active) { session in
                    SessionRow(session: session, workspace: model.workspace(for: session), now: now,
                               pending: model.pendingCount(for: session.id),
                               selected: session.id == model.selectedSessionId,
                               children: 0, expanded: false,
                               open: { open(session.id) }, archive: { Task { await model.archive(session.id) } }, toggleChildren: {})
                        .contextMenu { menu(for: session, archived: false) }
                }
                if !archived.isEmpty {
                    Text("已归档").uiFont(11).foregroundStyle(palette.ink4)
                        .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                    ForEach(archived) { session in
                        ArchivedRow(session: session, workspace: model.workspace(for: session), now: now,
                                    selected: session.id == model.selectedSessionId,
                                    open: { open(session.id) },
                                    restore: { Task { await model.unarchive(session.id) } })
                            .contextMenu { menu(for: session, archived: true) }
                    }
                }
                if active.isEmpty, archived.isEmpty {
                    Text("没有找到「\(needle)」").uiFont(12.5).foregroundStyle(palette.ink4)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for session: SessionSummary, archived: Bool) -> some View {
        Button("在新窗口打开") { layout.openConversation(session.id, mode: .newWindow) }
        Button("并排打开") { layout.openConversation(session.id, mode: .sideBySide) }
        Divider()
        if archived {
            Button("恢复") { Task { await model.unarchive(session.id) } }
        } else {
            Button("归档") { Task { await model.archive(session.id) } }
        }
    }

    private func open(_ id: String) {
        model.selectedSessionId = id
        layout.openConversation(id)
    }

    /// 选文件夹添加工作区；`thenNewSession` 时加好后直接在里面新建会话（⌘N 面板的「添加工作区…」）。
    static func chooseFolder(model: AppModel, thenNewSession: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "添加工作区"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addWorkspace(path: url.path(percentEncoded: false), thenNewSession: thenNewSession) }
    }
}

/// 侧栏顶部的搜索框；Esc 清空。
private struct SearchField: View {
    @Binding var text: String
    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").uiFont(12).foregroundStyle(palette.ink3)
            TextField("", text: $text, prompt: Text("搜索").foregroundStyle(palette.ink4))
                .textFieldStyle(.plain)
                .uiFont(13)
                .focused($focused)
                .onKeyPress(.escape) {
                    text = ""
                    focused = false
                    return .handled
                }
            if !text.isEmpty {
                Button("清除", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .uiFont(12)
                    .foregroundStyle(palette.ink4)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(palette.rowHover, in: .rect(cornerRadius: Metrics.rowRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(palette.rowOnStroke, lineWidth: 0.5)
        }
    }
}

/// 工作区标识：同明度同彩度、按路径换色相的小方块加首字母；「无项目」是空心方块。
struct WorkspaceMark: View {
    let workspace: Workspace?
    var size: CGFloat = 14
    @Environment(\.palette) private var palette

    var body: some View {
        if let workspace, !workspace.isDefault {
            Text(workspace.displayTitle.prefix(1).uppercased())
                .font(.system(size: size * 0.64, weight: .semibold))
                .foregroundStyle(palette.dark ? Palette.oklch(0.2, 0.02, 75, 1) : .white)
                .frame(width: size, height: size)
                .background(Self.color(for: workspace.path, dark: palette.dark), in: .rect(cornerRadius: size * 0.28))
        } else {
            RoundedRectangle(cornerRadius: size * 0.28)
                .strokeBorder(palette.ink4, lineWidth: 1)
                .frame(width: size, height: size)
        }
    }

    /// 路径做 FNV-1a 散列取 24 档色相之一，同一个工作区永远是同一个颜色。
    static func color(for path: String, dark: Bool) -> Color {
        var hash: UInt32 = 2166136261
        for byte in path.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        let hue = Double(hash % 24) * 15
        return Palette.oklch(dark ? 0.74 : 0.62, 0.11, hue, 1)
    }
}

/// 相对时间：1m、4h、2d（设计稿原样）。
private func shortAge(_ date: Date, now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes < 60 { return "\(max(1, minutes))m" }
    if minutes < 1440 { return "\(minutes / 60)h" }
    return "\(minutes / 1440)d"
}

/// 行底：选中是半透明白底加细描边，悬停更淡（沿用主窗口 v7 侧栏）。
private struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.rowRadius)
            .fill(selected ? palette.rowOn : hovering ? palette.rowHover : .clear)
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: Metrics.rowRadius).strokeBorder(palette.rowOnStroke, lineWidth: 0.5)
                }
            }
            .shadow(color: selected ? palette.cardShadowNear : .clear, radius: 1, y: 1)
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
                Image(systemName: "gearshape").uiFont(13)
                Text("设置")
                Spacer(minLength: 0)
            }
            .uiFont(13)
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

/// 主列表一行：上层是工作区标识与时间（运行中、待确认时换成状态，悬停时换成归档按钮），下层是标题。
private struct SessionRow: View {
    let session: SessionSummary
    let workspace: Workspace?
    let now: Date
    let pending: Int
    let selected: Bool
    let children: Int
    let expanded: Bool
    let open: () -> Void
    let archive: () -> Void
    let toggleChildren: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                WorkspaceMark(workspace: workspace)
                Text(workspace?.displayTitle ?? "")
                    .uiFont(11.5)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering, !session.running {
                    Button("归档", systemImage: "archivebox", action: archive)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .uiFont(11.5)
                        .foregroundStyle(palette.ink3)
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                        .help("归档")
                } else {
                    status
                }
            }
            .frame(height: 16)
            HStack(spacing: 4) {
                Text(session.displayTitle)
                    .uiFont(13)
                    .lineLimit(1)
                    .foregroundStyle(selected || hovering ? palette.ink : session.blank ? palette.ink3 : palette.ink2)
                Spacer(minLength: 4)
                if children > 0 {
                    Button(action: toggleChildren) {
                        HStack(spacing: 2) {
                            Text("\(children)").monospacedDigit()
                            Image(systemName: "chevron.right")
                                .uiFont(7, .bold)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .uiFont(11)
                        .foregroundStyle(palette.ink4)
                        .padding(.horizontal, 3)
                        .frame(height: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("子会话")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background { RowBackground(selected: selected, hovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var status: some View {
        if pending > 0 {
            HStack(spacing: 5) {
                Circle().fill(palette.warn).frame(width: 6, height: 6)
                Text("待确认")
            }
            .uiFont(11)
            .foregroundStyle(palette.ink2)
        } else if session.running {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(palette.accent)
                Text("运行中")
            }
            .uiFont(11)
            .foregroundStyle(palette.accent)
        } else if !session.blank {
            Text(shortAge(session.updatedAt, now: now))
                .uiFont(11)
                .monospacedDigit()
                .foregroundStyle(palette.ink4)
        }
    }
}

/// 子会话：缩进一级、单行，左侧一条细线连着父会话。
private struct ChildRow: View {
    let session: SessionSummary
    let selected: Bool
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(session.displayTitle).uiFont(12.5).lineLimit(1)
                .foregroundStyle(selected || hovering ? palette.ink : palette.ink3)
            Spacer(minLength: 4)
            if session.running { ProgressView().controlSize(.mini) }
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background { RowBackground(selected: selected, hovering: hovering) }
        .overlay(alignment: .leading) {
            Rectangle().fill(palette.ink5.opacity(0.6)).frame(width: 1).padding(.leading, 14)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}

/// 归档里的一行：单行，标识 + 标题 + 时间，悬停时时间换成恢复按钮。
private struct ArchivedRow: View {
    let session: SessionSummary
    let workspace: Workspace?
    let now: Date
    let selected: Bool
    let open: () -> Void
    let restore: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceMark(workspace: workspace)
            Text(session.displayTitle).uiFont(12.5).lineLimit(1)
                .foregroundStyle(selected || hovering ? palette.ink : palette.ink3)
            Spacer(minLength: 4)
            if hovering {
                Button("恢复", systemImage: "arrow.uturn.backward", action: restore)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .uiFont(11.5)
                    .foregroundStyle(palette.ink3)
                    .frame(width: 20, height: 16)
                    .contentShape(Rectangle())
                    .help("恢复")
            } else {
                Text(shortAge(session.updatedAt, now: now)).uiFont(11).monospacedDigit().foregroundStyle(palette.ink4)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background { RowBackground(selected: selected, hovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }
}
