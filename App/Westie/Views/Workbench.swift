import SwiftUI
import WestieKit

/// 五个面板的排布：主边栏、侧边栏通高；顶部、底部只在对话面板上下。
/// 外观按「面板」设计稿 v1 方向 A：每个窗口一张卡片，窗口和面板之间是外框露出的 8pt 缝，拖缝调大小。
struct Workbench: View {
    static let space = "workbench"

    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            if layout.isVisible(.primary) {
                panel(.primary)
                    .padding(.top, Metrics.lightsHeight - Metrics.gap)
                    .frame(width: layout.state(.primary).size)
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
        .padding(Metrics.gap)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { layout.bounds = $0 }
        .overlay(alignment: .topLeading) { sidebarToggle }
        .overlay { DragOverlay(layout: layout, model: model) }
        .background { FrameBackground() }
        .coordinateSpace(.named(Self.space))
        .ignoresSafeArea(.container, edges: .top)
    }

    private func panel(_ id: PanelID) -> some View {
        PanelView(panel: id, layout: layout, model: model)
    }

    /// 红绿灯右侧的主边栏开关。主边栏收起时它落进最左上角窗口的标题行。
    private var sidebarToggle: some View {
        Button("主边栏", systemImage: "sidebar.left") { layout.toggle(.primary) }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .help("显示或收起主边栏（⌃⌘S）")
            .disabled(!layout.canToggle(.primary))
            .padding(.leading, 80)
            .frame(height: Metrics.lightsHeight)
    }
}

/// 一个面板：把并排显示的窗口按面板方向排开，窗口之间的缝可以拖动调整占比。
private struct PanelView: View {
    let panel: PanelID
    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette
    @State private var dragStart: (lead: Double, trail: Double)?

    var body: some View {
        let windows = layout.shownWindows(in: panel)
        Group {
            if windows.isEmpty {
                EmptyCenterView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .card(palette)
            } else {
                GeometryReader { proxy in
                    let horizontal = panel.isHorizontal
                    let total = (horizontal ? proxy.size.width : proxy.size.height) - Metrics.gap * Double(windows.count - 1)
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
                                    let minimum = min(pair / 2, 200 / total * sum)
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

/// 面板之间的缝：拖动改面板尺寸。
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

/// 8pt 的缝本身就是拖动区域；悬停或拖动时缝中间亮出一小段强调色。`horizontal` 为真表示左右分隔。
struct SplitHandle: View {
    let horizontal: Bool
    let onBegin: () -> Void
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    @Environment(\.palette) private var palette
    @State private var active = false
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: horizontal ? Metrics.gap : nil, height: horizontal ? nil : Metrics.gap)
            .overlay {
                GeometryReader { proxy in
                    Capsule()
                        .fill(palette.accent.opacity(active || hovering ? 0.5 : 0))
                        .frame(
                            width: horizontal ? 2 : proxy.size.width * 0.4,
                            height: horizontal ? proxy.size.height * 0.4 : 2
                        )
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .animation(.easeOut(duration: 0.16), value: active || hovering)
                }
            }
            .contentShape(Rectangle())
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .onHover { hovering = $0 }
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
}

/// 一个窗口。会话列表这类导航窗口直接坐在外框上，其余窗口是卡片。
private struct WindowTile: View {
    let panel: PanelID
    let window: PanelWindow
    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var focused: Bool { layout.focusedWindowId == window.id }
    private var onFrame: Bool { window.content == .sessions }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(TileSurface(onFrame: onFrame, palette: palette))
        .opacity(layout.drag?.windowId == window.id ? 0.35 : 1)
        .animation(.easeOut(duration: 0.16), value: layout.drag?.windowId == window.id)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { layout.focus(window.id) })
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Workbench.space)) } action: {
            layout.tileFrames[window.id] = $0
        }
    }

    /// 主边栏收起时，红绿灯和开关落在最左上角窗口的标题行里，标题让出位置。
    private var holdsLights: Bool {
        guard !layout.isVisible(.primary) else { return false }
        switch panel {
        case .top: return layout.state(.top).shown.first == window.id
        case .center: return !layout.isVisible(.top) && layout.state(.center).shown.first == window.id
        default: return false
        }
    }

    private var leading: CGFloat {
        if holdsLights { return 112 }
        if onFrame { return 8 }
        return panel.isHorizontal ? 24 : 16
    }

    private var header: some View {
        HStack(spacing: 4) {
            title
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if onFrame {
                    Button("添加工作区", systemImage: "folder.badge.plus") { SidebarView.chooseFolder(model: model) }
                        .help("添加工作区")
                }
                Menu {
                    moreItems
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("窗口操作")
                Button("关闭窗口", systemImage: "xmark") { layout.close(window.id) }
                    .help("关闭窗口")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle())
            .menuStyle(.button)
            .opacity(hovering ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
        .padding(.leading, leading)
        .padding(.trailing, 8)
        .frame(height: onFrame ? 36 : 44)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named(Workbench.space))
                .onChanged { layout.updateDrag(window.id, at: $0.location) }
                .onEnded { _ in layout.endDrag() }
        )
    }

    /// 面板里有收着的窗口时，标题变成切换菜单（带一个小箭头）。
    @ViewBuilder
    private var title: some View {
        let hidden = layout.hiddenWindows(in: panel)
        let label = HStack(spacing: 2) {
            Text(window.content.title(model: model))
                .lineLimit(1)
            if !hidden.isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.ink3)
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(focused || onFrame ? palette.ink : palette.ink2)

        if hidden.isEmpty {
            label
        } else {
            Menu {
                Section("切换到") {
                    ForEach(hidden) { other in
                        Button(other.content.title(model: model)) { layout.reveal(other.id) }
                    }
                }
                Section("并排显示") {
                    ForEach(hidden) { other in
                        Button(other.content.title(model: model), systemImage: "rectangle.split.2x1") {
                            layout.showSideBySide(other.id)
                        }
                    }
                }
            } label: {
                label
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换窗口")
        }
    }

    @ViewBuilder
    private var moreItems: some View {
        Section("移到") {
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
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct TileSurface: ViewModifier {
    let onFrame: Bool
    let palette: Palette

    func body(content: Content) -> some View {
        if onFrame {
            content
        } else {
            content.card(palette)
        }
    }
}

/// 28pt 的图标按钮：平时墨色三档，悬停加一层浅底。
struct IconButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .foregroundStyle(hovering ? palette.ink : palette.ink3)
            .background(hovering || configuration.isPressed ? palette.rowHoverSolid : .clear, in: .rect(cornerRadius: Metrics.rowRadius))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

/// 拖动窗口时：不显示的面板在边缘露出虚线落点，目标位置画插入线，光标处跟一个窗口名。
private struct DragOverlay: View {
    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        if let drag = layout.drag {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.dropZones()), id: \.key) { panel, zone in
                    let hot = drag.target?.panel == panel
                    RoundedRectangle(cornerRadius: Metrics.cardRadius)
                        .fill(hot ? palette.zoneHot : .clear)
                        .background(.ultraThinMaterial, in: .rect(cornerRadius: Metrics.cardRadius))
                        .background(palette.zone, in: .rect(cornerRadius: Metrics.cardRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: Metrics.cardRadius)
                                .strokeBorder(hot ? palette.accent : palette.ink4, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                        .overlay {
                            Text(panel.title).font(.system(size: 11)).foregroundStyle(hot ? palette.ink : palette.ink3)
                        }
                        .frame(width: zone.width, height: zone.height)
                        .offset(x: zone.minX, y: zone.minY)
                        .transition(.opacity)
                }
                if let target = drag.target, layout.dropZones()[target.panel] == nil,
                   let frame = layout.indicatorFrame(for: target, dragging: drag.windowId) {
                    let fills = frame.width > 8 && frame.height > 8
                    RoundedRectangle(cornerRadius: fills ? Metrics.cardRadius : 1.5)
                        .fill(fills ? palette.zoneHot : palette.accent)
                        .overlay {
                            if fills {
                                RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(palette.accent, lineWidth: 1)
                            }
                        }
                        .frame(width: fills ? frame.width : (frame.width > frame.height ? frame.width - 16 : 3),
                               height: fills ? frame.height : (frame.width > frame.height ? 3 : frame.height - 16))
                        .offset(x: fills ? frame.minX : (frame.width > frame.height ? frame.minX + 8 : frame.midX - 1.5),
                                y: fills ? frame.minY : (frame.width > frame.height ? frame.midY - 1.5 : frame.minY + 8))
                        .animation(.easeOut(duration: 0.12), value: frame)
                }
                if let window = layout.locate(drag.windowId)?.window {
                    Text(window.content.title(model: model))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(palette.box, in: .capsule)
                        .overlay(Capsule().strokeBorder(palette.boxStroke, lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                        .fixedSize()
                        .offset(x: drag.location.x + 12, y: drag.location.y + 10)
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
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            if model.board.ordered.isEmpty {
                Text("还没有工作区").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                Button("打开文件夹…") { SidebarView.chooseFolder(model: model) }
            } else {
                Text("选择或新建一个会话").font(.system(size: 13)).foregroundStyle(palette.ink3)
            }
        }
    }
}

extension WindowContent {
    @MainActor
    func title(model: AppModel) -> String {
        switch self {
        case .sessions: "Westie"
        case .conversation(let id): model.sessions[id]?.displayTitle ?? "会话"
        }
    }
}
