import AppKit
import SwiftUI
import WestieKit

/// 会话列表窗口：直接坐在外框上（设计稿 2026-10-29-session-list v1、v2）。
/// 置顶的会话排在最前，其余不分组、按最近活动排成一列，工作区是每行的标识；手动归档的收在底部「归档」。
struct SidebarView: View {
    @Bindable var model: AppModel
    let layout: PanelLayout
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var expanded: Set<String> = []
    @State private var archiveOpen = false
    @State private var renaming: String?
    /// 正文命中；nil 表示还在查。
    @State private var contentHits: [AppModel.SearchHit]?

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

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
                    if needle.isEmpty {
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
        // 标题结果即时出；正文停手 300ms 后再查，换了关键词就丢掉旧结果。
        .task(id: needle) {
            contentHits = nil
            guard !needle.isEmpty else { return }
            guard model.contentSearchAvailable else { contentHits = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let hits = (try? await model.searchContent(needle)) ?? []
            guard !Task.isCancelled else { return }
            contentHits = hits
        }
    }

    /// 设置卡片正聚焦时，入口跟会话行一样高亮。
    private var settingsFocused: Bool {
        layout.focusedWindowId.flatMap { layout.locate($0) }?.window.content == .settings
    }

    private func sessionList(now: Date) -> some View {
        let pinned = model.pinnedSessions
        let timeline = model.timelineSessions
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(pinned) { session in
                        sessionGroup(session, now: now)
                    }
                    if !pinned.isEmpty, !timeline.isEmpty {
                        Rectangle().fill(palette.ink5.opacity(0.5)).frame(height: 0.5)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                    }
                    ForEach(timeline) { session in
                        sessionGroup(session, now: now)
                    }
                }
                .padding(.bottom, 8)
            }
            // 新建、恢复或从别处选中的会话滚进视野；选中的是子 Agent 会话就先展开它的父会话。
            .onChange(of: model.selectedSessionId) { _, id in
                guard let id, let session = model.sessions[id] else { return }
                let owner = model.topLevelAncestor(of: session)
                guard model.activeSessions.contains(where: { $0.id == owner.id }) else { return }
                if owner.id != id { expanded.insert(owner.id) }
                Task { @MainActor in
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { proxy.scrollTo(id) }
                }
            }
        }
        .scrollIndicators(.never)
        .mask {
            LinearGradient(stops: [.init(color: .black, location: 0.94), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxHeight: .infinity)
    }

    /// 一个会话行，展开时下面跟着它的子 Agent 会话。
    private func sessionGroup(_ session: SessionSummary, now: Date) -> some View {
        let children = model.children(of: session.id)
        return VStack(alignment: .leading, spacing: 2) {
            sessionRow(session, now: now, children: children.count)
            if expanded.contains(session.id) {
                ForEach(children) { child in
                    childRow(child)
                }
            }
        }
        .id(session.id)
    }

    private func sessionRow(_ session: SessionSummary, now: Date, children: Int) -> some View {
        SessionRow(
            session: session,
            workspace: model.workspace(for: session),
            lastActive: model.lastActive(session),
            now: now,
            pending: model.pendingCountIncludingChildren(for: session.id),
            busy: model.isBusy(session),
            pinned: model.isPinned(session.id),
            selected: session.id == model.selectedSessionId,
            children: children,
            expanded: expanded.contains(session.id),
            renaming: Binding(get: { renaming == session.id }, set: { if !$0 { renaming = nil } }),
            open: { open(session.id) },
            archive: { Task { await model.archive(session.id) } },
            togglePin: { Task { await model.togglePin(session.id) } },
            rename: { title in Task { await model.rename(session.id, to: title) } },
            startRename: { renaming = session.id },
            toggleChildren: { toggle(session.id) }
        )
        .onDrag { SessionDrag.begin(session.id) } preview: {
            Text(session.displayTitle).uiFont(13).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(palette.box, in: .rect(cornerRadius: Metrics.rowRadius))
        }
        .contextMenu { menu(for: session, archived: false) }
    }

    private func childRow(_ child: SessionSummary) -> some View {
        ChildRow(session: child, selected: child.id == model.selectedSessionId,
                 pending: model.pendingCount(for: child.id)) { open(child.id) }
            .id(child.id)
            .onDrag { SessionDrag.begin(child.id) }
            .contextMenu {
                Button("在新窗口打开") { layout.openConversation(child.id, mode: .newWindow) }
                Button("并排打开") { layout.openConversation(child.id, mode: .sideBySide) }
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
                            VStack(spacing: 2) {
                                archivedRow(session, now: now)
                                // 归档的父会话也能展开看它的子代理会话
                                if expanded.contains(session.id) {
                                    ForEach(model.children(of: session.id)) { childRow($0) }
                                }
                            }
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

    private func archivedRow(_ session: SessionSummary, now: Date, showsChildren: Bool = true) -> some View {
        ArchivedRow(session: session, workspace: model.workspace(for: session), lastActive: model.lastActive(session), now: now,
                    selected: session.id == model.selectedSessionId,
                    children: showsChildren ? model.children(of: session.id).count : 0,
                    expanded: expanded.contains(session.id),
                    open: { open(session.id) },
                    restore: { restore(session.id) },
                    toggleChildren: { toggle(session.id) })
            .contextMenu { menu(for: session, archived: true) }
    }

    /// 搜索：先即时匹配标题和工作区名（进行中、已归档、子 Agent 会话都算），再补上正文命中的会话和一段原文。
    private func searchResults(now: Date) -> some View {
        func matches(_ session: SessionSummary) -> Bool {
            session.displayTitle.localizedCaseInsensitiveContains(needle)
                || (model.workspace(for: session)?.displayTitle.localizedCaseInsensitiveContains(needle) ?? false)
        }
        let active = model.activeSessions.filter(matches)
        let archived = model.archivedSessions.filter(matches)
        let children = model.sessions.values.filter { $0.isSubagent && matches($0) }.sorted { model.lastActive($0) > model.lastActive($1) }
        let shown = Set((active + archived + children).map(\.id))
        let content = (contentHits ?? []).filter { !shown.contains($0.sessionId) && model.sessions[$0.sessionId] != nil }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(active) { session in
                    sessionRow(session, now: now, children: 0)
                }
                ForEach(children) { child in
                    childRow(child)
                }
                if !archived.isEmpty {
                    groupLabel("已归档")
                    ForEach(archived) { session in
                        archivedRow(session, now: now, showsChildren: false)
                    }
                }
                if contentHits == nil, model.contentSearchAvailable {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("正在搜索内容…")
                    }
                    .uiFont(11).foregroundStyle(palette.ink4)
                    .padding(.horizontal, 8).padding(.top, 10)
                } else if !content.isEmpty {
                    groupLabel("内容")
                    ForEach(content) { hit in
                        if let session = model.sessions[hit.sessionId] {
                            ContentHitRow(session: session, workspace: model.workspace(for: session),
                                          lastActive: model.lastActive(session), now: now, snippet: hit.snippet, needle: needle,
                                          selected: session.id == model.selectedSessionId) { open(session.id) }
                        }
                    }
                }
                if contentHits != nil, active.isEmpty, archived.isEmpty, children.isEmpty, content.isEmpty {
                    Text("没有找到「\(needle)」").uiFont(12.5).foregroundStyle(palette.ink4)
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text).uiFont(11).foregroundStyle(palette.ink4)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
    }

    @ViewBuilder
    private func menu(for session: SessionSummary, archived: Bool) -> some View {
        Button("在新窗口打开") { layout.openConversation(session.id, mode: .newWindow) }
        Button("并排打开") { layout.openConversation(session.id, mode: .sideBySide) }
        Divider()
        if !archived {
            Button(model.isPinned(session.id) ? "取消置顶" : "置顶") { Task { await model.togglePin(session.id) } }
            Button("重命名") { renaming = session.id }
        }
        Button("从这里分叉") {
            Task { if let id = await model.fork(session.id) { layout.openConversation(id) } }
        }
        Divider()
        if archived {
            Button("恢复") { restore(session.id) }
        } else {
            Button("归档") { Task { await model.archive(session.id) } }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.24)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func open(_ id: String) {
        model.selectedSessionId = id
        layout.openConversation(id)
    }

    /// 恢复后它排到时间线最上面，并打开它。
    private func restore(_ id: String) {
        Task {
            guard await model.unarchive(id) else { return }
            open(id)
        }
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

/// 从侧栏拖出的会话：放到对话窗口上就在那里打开，放到右侧三分之一就并排打开。
/// 拖的是带前缀的纯文本，不用另外登记文件类型；落点只认这个前缀。
/// 拖动开始时记下是哪个会话：落点据此只接本 App 的会话拖动，普通文本照常交给输入框。
@MainActor
enum SessionDrag {
    static let prefix = "westie-session:"
    private static var current: (sessionId: String, startedAt: Date)?

    static func begin(_ sessionId: String) -> NSItemProvider {
        current = (sessionId, Date())
        return NSItemProvider(object: (prefix + sessionId) as NSString)
    }

    /// 正在拖的会话（拖动取消时没有回调，超过一分钟的记录视为过期）。
    static var active: String? {
        guard let current, Date().timeIntervalSince(current.startedAt) < 60 else { return nil }
        return current.sessionId
    }

    static func end() { current = nil }

    static func sessionId(from text: String) -> String? {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : nil
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

/// 主列表一行：上层是工作区标识与时间（运行中、待确认时换成状态，悬停时换成置顶、归档按钮），下层是标题。
/// 置顶的会话时间前多一枚图钉；重命名时标题原地变成输入框。
private struct SessionRow: View {
    let session: SessionSummary
    let workspace: Workspace?
    let lastActive: Date
    let now: Date
    let pending: Int
    let busy: Bool
    let pinned: Bool
    let selected: Bool
    let children: Int
    let expanded: Bool
    @Binding var renaming: Bool
    let open: () -> Void
    let archive: () -> Void
    let togglePin: () -> Void
    let rename: (String) -> Void
    let startRename: () -> Void
    let toggleChildren: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                WorkspaceMark(workspace: workspace)
                Text(workspace?.displayTitle ?? "")
                    .uiFont(11.5)
                    .foregroundStyle(palette.ink3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering, !renaming {
                    HStack(spacing: 1) {
                        rowButton(pinned ? "取消置顶" : "置顶", icon: pinned ? "pin.fill" : "pin", action: togglePin)
                        if !busy { rowButton("归档", icon: "archivebox", action: archive) }
                    }
                } else {
                    status
                }
            }
            .frame(height: 16)
            HStack(spacing: 4) {
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .uiFont(13)
                        .foregroundStyle(palette.ink)
                        .focused($editing)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(palette.box, in: .rect(cornerRadius: 4))
                        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(palette.boxStroke, lineWidth: 0.5) }
                        .padding(.horizontal, -4)
                        .padding(.vertical, -1)
                        .onSubmit(finish)
                        .onKeyPress(.escape) {
                            renaming = false
                            return .handled
                        }
                        .onChange(of: editing) { _, focused in if !focused, renaming { finish() } }
                        .onAppear {
                            draft = session.title ?? ""
                            editing = true
                        }
                } else {
                    Text(session.displayTitle)
                        .uiFont(13)
                        .lineLimit(1)
                        .foregroundStyle(selected || hovering ? palette.ink : session.blank ? palette.ink3 : palette.ink2)
                }
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
                    .help("子代理会话")
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background { RowBackground(selected: selected, hovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !session.blank { startRename() } }
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }

    private func finish() {
        renaming = false
        rename(draft)
    }

    private func rowButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .uiFont(11.5)
            .foregroundStyle(palette.ink3)
            .frame(width: 20, height: 16)
            .contentShape(Rectangle())
            .help(title)
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
        } else if busy {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(palette.accent)
                Text("运行中")
            }
            .uiFont(11)
            .foregroundStyle(palette.accent)
        } else if !session.blank {
            HStack(spacing: 4) {
                if pinned { Image(systemName: "pin.fill").uiFont(8).foregroundStyle(palette.ink4) }
                Text(shortAge(lastActive, now: now))
            }
            .uiFont(11)
            .monospacedDigit()
            .foregroundStyle(palette.ink4)
        }
    }
}

/// 正文命中：标识 + 标题 + 时间，下面一两行原文，关键词高亮。
private struct ContentHitRow: View {
    let session: SessionSummary
    let workspace: Workspace?
    let lastActive: Date
    let now: Date
    let snippet: String
    let needle: String
    let selected: Bool
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                WorkspaceMark(workspace: workspace)
                Text(session.displayTitle).uiFont(12.5).lineLimit(1)
                    .foregroundStyle(selected || hovering ? palette.ink : palette.ink2)
                Spacer(minLength: 4)
                Text(shortAge(lastActive, now: now)).uiFont(11).monospacedDigit().foregroundStyle(palette.ink4)
            }
            Text(highlighted)
                .uiFont(12)
                .foregroundStyle(palette.ink3)
                .lineLimit(2)
                .padding(.leading, 20)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background { RowBackground(selected: selected, hovering: hovering) }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
    }

    private var highlighted: AttributedString {
        let flat = snippet.replacingOccurrences(of: "\n", with: " ")
        var text = AttributedString(flat)
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text[searchStart...].range(of: needle, options: .caseInsensitive) {
            text[range].backgroundColor = palette.warn.opacity(palette.dark ? 0.35 : 0.3)
            text[range].foregroundColor = palette.ink
            searchStart = range.upperBound
        }
        return text
    }
}

/// 子会话：缩进一级、单行，左侧一条细线连着父会话。
private struct ChildRow: View {
    let session: SessionSummary
    let selected: Bool
    var pending = 0
    let open: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(session.displayTitle).uiFont(12.5).lineLimit(1)
                .foregroundStyle(selected || hovering ? palette.ink : palette.ink3)
            Spacer(minLength: 4)
            if pending > 0 {
                Circle().fill(palette.warn).frame(width: 6, height: 6)
            } else if session.running {
                ProgressView().controlSize(.mini)
            }
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
    let lastActive: Date
    let now: Date
    let selected: Bool
    var children = 0
    var expanded = false
    let open: () -> Void
    let restore: () -> Void
    var toggleChildren: () -> Void = {}
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceMark(workspace: workspace)
            Text(session.displayTitle).uiFont(12.5).lineLimit(1)
                .foregroundStyle(selected || hovering ? palette.ink : palette.ink3)
            Spacer(minLength: 4)
            if children > 0 {
                Button(action: toggleChildren) {
                    HStack(spacing: 2) {
                        Text("\(children)").monospacedDigit()
                        Image(systemName: "chevron.right").uiFont(7, .bold).rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .uiFont(11)
                    .foregroundStyle(palette.ink4)
                    .padding(.horizontal, 3)
                    .frame(height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("子代理会话")
            }
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
                Text(shortAge(lastActive, now: now)).uiFont(11).monospacedDigit().foregroundStyle(palette.ink4)
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
