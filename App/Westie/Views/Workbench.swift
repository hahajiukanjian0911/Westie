import SwiftUI
import WestieKit

/// 五个面板的排布：主边栏、侧边栏通高；顶部、底部只在对话面板上下。
struct Workbench: View {
    static let space = "workbench"

    let layout: PanelLayout
    let model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if layout.isVisible(.primary) {
                panel(.primary).frame(width: layout.state(.primary).size)
                PanelDivider(panel: .primary, layout: layout)
            }
            VStack(spacing: 0) {
                if layout.isVisible(.top) {
                    panel(.top).frame(height: layout.state(.top).size)
                    PanelDivider(panel: .top, layout: layout)
                }
                panel(.center)
                if layout.isVisible(.bottom) {
                    PanelDivider(panel: .bottom, layout: layout)
                    panel(.bottom).frame(height: layout.state(.bottom).size)
                }
            }
            if layout.isVisible(.secondary) {
                PanelDivider(panel: .secondary, layout: layout)
                panel(.secondary).frame(width: layout.state(.secondary).size)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { layout.bounds = $0 }
        .overlay { DragOverlay(layout: layout, model: model) }
        .coordinateSpace(.named(Self.space))
    }

    private func panel(_ id: PanelID) -> some View {
        PanelView(panel: id, layout: layout, model: model)
    }
}

/// 一个面板：把并排显示的窗口按面板方向排开，窗口之间可以拖动分隔条调整占比。
private struct PanelView: View {
    let panel: PanelID
    let layout: PanelLayout
    let model: AppModel
    @State private var dragStart: (lead: Double, trail: Double)?

    var body: some View {
        let windows = layout.shownWindows(in: panel)
        Group {
            if windows.isEmpty {
                EmptyCenterView(model: model)
            } else {
                GeometryReader { proxy in
                    let horizontal = panel.isHorizontal
                    let total = horizontal ? proxy.size.width : proxy.size.height
                    let weights = windows.map { layout.weight(of: $0.id, in: panel) }
                    let sum = weights.reduce(0, +)
                    let stack = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    stack {
                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                            if index > 0 {
                                SplitHandle(horizontal: horizontal) {
                                    let lead = windows[index - 1].id, trail = window.id
                                    dragStart = (layout.weight(of: lead, in: panel), layout.weight(of: trail, in: panel))
                                } onDrag: { translation in
                                    guard let start = dragStart, total > 0 else { return }
                                    let lead = windows[index - 1].id, trail = window.id
                                    let pair = start.lead + start.trail
                                    let minimum = min(pair / 2, 160 / total * sum)
                                    let moved = min(max(start.lead + translation / total * sum, minimum), pair - minimum)
                                    layout.setWeights([lead: moved, trail: pair - moved], in: panel)
                                } onEnd: {
                                    dragStart = nil
                                    layout.save()
                                }
                            }
                            let length = total * weights[index] / sum
                            WindowTile(panel: panel, window: window, layout: layout, model: model)
                                .frame(width: horizontal ? length : nil, height: horizontal ? nil : length)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Workbench.space)) } action: { layout.panelFrames[panel] = $0 }
    }
}

/// 面板之间的分隔条：拖动改面板尺寸。
private struct PanelDivider: View {
    let panel: PanelID
    let layout: PanelLayout
    @State private var start: Double?

    var body: some View {
        SplitHandle(horizontal: !panel.isHorizontal) {
            start = layout.state(panel).size
        } onDrag: { translation in
            guard let start else { return }
            let sign: Double = (panel == .primary || panel == .top) ? 1 : -1
            layout.setSize(start + sign * translation, of: panel)
        } onEnd: {
            start = nil
            layout.save()
        }
    }
}

/// 1pt 分隔线，两侧各留 4pt 可拖区域。`horizontal` 为真表示左右分隔（竖线、横向拖动）。
struct SplitHandle: View {
    let horizontal: Bool
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    @State private var active = false

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 9 : nil, height: horizontal ? nil : 9)
                    .contentShape(Rectangle())
                    .pointerStyle(horizontal ? .columnResize : .rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !active {
                                    active = true
                                    onBegin()
                                }
                                onDrag(horizontal ? value.translation.width : value.translation.height)
                            }
                            .onEnded { _ in
                                active = false
                                onEnd()
                            }
                    )
            }
            .zIndex(1)
    }
}

/// 一个窗口：标题条（拖动、切换、移动、关闭）加内容。
private struct WindowTile: View {
    let panel: PanelID
    let window: PanelWindow
    let layout: PanelLayout
    let model: AppModel

    private var focused: Bool { layout.focusedWindowId == window.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opacity(layout.drag?.windowId == window.id ? 0.4 : 1)
        .simultaneousGesture(TapGesture().onEnded { layout.focus(window.id) })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Workbench.space)) } action: {
            layout.tileFrames[window.id] = $0
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: window.content.symbol)
                .foregroundStyle(.secondary)
            Text(window.content.title(model: model))
                .lineLimit(1)
                .foregroundStyle(focused ? .primary : .secondary)
            Spacer(minLength: 4)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("窗口操作")
            Button("关闭窗口", systemImage: "xmark") { layout.close(window.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("关闭窗口")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(focused ? Color.accentColor.opacity(0.08) : .clear, ignoresSafeAreaEdges: [])
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Workbench.space))
                .onChanged { layout.updateDrag(window.id, at: $0.location) }
                .onEnded { _ in layout.endDrag() }
        )
    }

    @ViewBuilder
    private var menuItems: some View {
        let hidden = layout.hiddenWindows(in: panel)
        if !hidden.isEmpty {
            Section("切换到") {
                ForEach(hidden) { other in
                    Button(other.content.title(model: model)) { layout.reveal(other.id) }
                }
            }
            Menu("并排显示") {
                ForEach(hidden) { other in
                    Button(other.content.title(model: model)) { layout.showSideBySide(other.id) }
                }
            }
        }
        Menu("移到") {
            ForEach(PanelID.allCases.filter { $0 != panel }) { target in
                Button(target.title) { layout.move(window.id, to: target) }
            }
        }
        Divider()
        Button("收起窗口") { layout.hide(window.id) }
        Button("关闭窗口") { layout.close(window.id) }
    }

    @ViewBuilder
    private var content: some View {
        switch window.content {
        case .sessions:
            SidebarView(model: model, layout: layout)
        case .conversation(let sessionId):
            if let conversation = model.conversations[sessionId] {
                ConversationView(model: model, conversation: conversation)
                    .id(sessionId)
            } else {
                ProgressView()
            }
        }
    }
}

/// 拖动窗口时：不显示的面板露出落点，目标位置画提示，光标处跟一个窗口名。
private struct DragOverlay: View {
    let layout: PanelLayout
    let model: AppModel

    var body: some View {
        if let drag = layout.drag {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.dropZones()), id: \.key) { panel, zone in
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
                        .overlay { Text(panel.title).font(.caption).foregroundStyle(.secondary) }
                        .frame(width: zone.width - 8, height: zone.height - 8)
                        .offset(x: zone.minX + 4, y: zone.minY + 4)
                }
                if let target = drag.target, let frame = layout.indicatorFrame(for: target, dragging: drag.windowId) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(frame.width > 8 && frame.height > 8 ? 0.15 : 0.9))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                if let window = layout.locate(drag.windowId)?.window {
                    Label(window.content.title(model: model), systemImage: window.content.symbol)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.regularMaterial, in: .capsule)
                        .fixedSize()
                        .offset(x: drag.location.x + 12, y: drag.location.y + 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }
}

/// 对话面板里没有窗口时。
private struct EmptyCenterView: View {
    let model: AppModel

    var body: some View {
        if model.board.ordered.isEmpty {
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

extension WindowContent {
    var symbol: String {
        switch self {
        case .sessions: "list.bullet"
        case .conversation: "bubble.left.and.text.bubble.right"
        }
    }

    @MainActor
    func title(model: AppModel) -> String {
        switch self {
        case .sessions: "会话"
        case .conversation(let id): model.sessions[id]?.displayTitle ?? "会话"
        }
    }
}
