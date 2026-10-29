import AppKit
import SwiftUI
import WestieKit

/// 五个面板的排布：主边栏、侧边栏通高；顶部、底部只在对话面板上下。
/// 外观按「面板」设计稿 v1 方向 A：每个窗口一张卡片，窗口和面板之间是外框露出的 8pt 缝，拖缝调大小。
/// 拖放按 v3：外圈开面板、窗口卡片前中后分并排与叠放、上沿布局条、标题栏布局按钮、移走后补位。
struct Workbench: View {
    static let space = "workbench"
    /// 松手或移动窗口后各窗口归位的弹簧。
    static let settle = Animation.spring(duration: 0.38, bounce: 0.22)

    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette
    @Namespace private var tiles
    @State private var assistMonitor: Any?

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
        .coordinateSpace(.named(Self.space))
        .ignoresSafeArea(.container, edges: .top)
        .onAppear(perform: watchAssist)
        .onDisappear {
            if let assistMonitor { NSEvent.removeMonitor(assistMonitor) }
            assistMonitor = nil
        }
    }

    private func panel(_ id: PanelID) -> some View {
        PanelView(panel: id, layout: layout, model: model, tiles: tiles)
    }

    /// 拖动窗口时按 Esc 取消。补位时：点补位区以外的地方或按 Esc 就收掉。只旁听事件，不拦截点击。
    private func watchAssist() {
        guard assistMonitor == nil else { return }
        assistMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { [layout] event in
            if event.type == .keyDown, event.keyCode == 53, layout.drag != nil {
                withAnimation(Workbench.settle) { layout.cancelDrag() }
                return nil
            }
            guard !layout.assisting.isEmpty else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                withAnimation(Workbench.settle) { layout.dismissAssist() }
                return nil
            }
            if let view = event.window?.contentView {
                let point = view.convert(event.locationInWindow, from: nil)
                let flipped = view.isFlipped ? point : CGPoint(x: point.x, y: view.bounds.height - point.y)
                if layout.assisting.contains(where: { layout.panelFrames[$0]?.contains(flipped) == true }) { return event }
            }
            DispatchQueue.main.async { withAnimation(Workbench.settle) { layout.dismissAssist() } }
            return event
        }
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
    let tiles: Namespace.ID
    @Environment(\.palette) private var palette
    @State private var dragStart: (lead: Double, trail: Double)?

    var body: some View {
        let windows = layout.shownWindows(in: panel)
        Group {
            // 对话面板没有开关，窗口全收起时就一直列出收着的窗口，免得找不回来。
            if windows.isEmpty, layout.assisting.contains(panel) || (panel == .center && !layout.hiddenWindows(in: panel).isEmpty) {
                AssistView(panel: panel, layout: layout, model: model)
            } else if windows.isEmpty {
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
                                .matchedGeometryEffect(id: window.id, in: tiles)
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
    @State private var nearGrip = false
    @State private var onGrip = false
    @State private var showingMap = false

    private var focused: Bool { layout.focusedWindowId == window.id }
    private var onFrame: Bool { window.content == .sessions }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(TileSurface(onFrame: onFrame, palette: palette))
        .overlay(alignment: .top) {
            WindowGrip(shown: gripShown, highlighted: onGrip)
        }
        .opacity(layout.drag?.windowId == window.id ? 0.35 : 1)
        .animation(.easeOut(duration: 0.16), value: layout.drag?.windowId == window.id)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hovering = true
                let width = layout.tileFrames[window.id]?.width ?? 0
                let dx = abs(point.x - width / 2)
                nearGrip = point.y < WindowGrip.reach.height && dx < WindowGrip.reach.width / 2
                onGrip = point.y < 16 && dx < 36
            case .ended:
                hovering = false
                nearGrip = false
                onGrip = false
            }
        }
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
                Button("移动窗口", systemImage: "square.grid.3x1.below.line.grid.1x2") { showingMap = true }
                    .help("移动窗口")
                    .popover(isPresented: $showingMap, arrowEdge: .bottom) {
                        LayoutMap(current: panel, layout: layout, interactive: true) { target in
                            showingMap = false
                            layout.hoverTarget = nil
                            guard target != panel else { return }
                            withAnimation(Workbench.settle) { layout.move(window.id, to: target) }
                        } onHover: { target in
                            layout.hoverTarget = target.map { layout.appendTarget($0, dragging: window.id) }
                        }
                        .padding(8)
                    }
                    .onChange(of: showingMap) { if !showingMap { layout.hoverTarget = nil } }
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
            .opacity(hovering || showingMap ? 1 : 0)
            .animation(.easeOut(duration: 0.16), value: hovering)
        }
        .padding(.leading, leading)
        .padding(.trailing, 8)
        .frame(height: onFrame ? 36 : 44)
        .background { dragArea }
    }

    /// 标题栏空白处（拖动条就画在它上面）：拖着窗口换位置。
    private var dragArea: WindowDragArea {
        WindowDragArea {
            layout.focus(window.id)
        } onDrag: { location, start in
            layout.updateDrag(window.id, at: location, from: start)
        } isDragging: {
            layout.drag?.windowId == window.id
        } onEnd: {
            withAnimation(Workbench.settle) { layout.endDrag() }
        } onCancel: {
            layout.cancelDrag()
        }
    }

    /// 指针靠近窗口顶部正中，或正拖着这个窗口时，亮出拖动条。
    private var gripShown: Bool {
        #if DEBUG
        if layout.gripsShown { return true }
        #endif
        return nearGrip || layout.drag?.windowId == window.id
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
                // 会话模型下一帧就建好，这里留空，不闪转圈
                Color.clear
            }
        }
    }
}

/// 窗口顶部正中的拖动条：平时不显示，指针靠近才浮出，提示这里能拖动窗口。
private struct WindowGrip: View {
    /// 指针进入窗口顶部正中这块范围内就浮出。
    static let reach = CGSize(width: 180, height: 28)
    let shown: Bool
    let highlighted: Bool
    @Environment(\.palette) private var palette

    /// 只画出来，不接事件：拖动由标题栏底下的拖动区域接，窄窗口里与按钮重叠时按钮优先。
    var body: some View {
        Capsule()
            .fill(highlighted ? palette.ink3 : palette.ink4)
            .frame(width: highlighted ? 40 : 32, height: 4)
            .padding(.top, 5)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -3)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.16), value: shown)
            .animation(.spring(duration: 0.2, bounce: 0.2), value: highlighted)
    }
}

/// 拖动 App 的地方只有外框露出来的部分。隐藏标题栏那一条默认整条都拖 App，会抢走窗口标题栏和拖动条上的拖动，
/// 所以关掉系统的自动拖动（`isMovable = false`），由外框自己调 `performDrag`；双击照系统设置缩放或最小化。
struct AppMoveArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }
    func updateNSView(_ view: AreaView, context: Context) {}

    final class AreaView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isMovable = false
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
                if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
                return
            }
            // 系统自动拖动关着；主动拖时临时打开，拖完恢复（与 cmux 的 WindowDragHandleView 同法）。
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = false
        }
    }
}

/// 拖动窗口的区域：标题栏空白处和顶部拖动条。用 AppKit 视图自己接按下和拖动，坐标换成 Workbench 坐标（与窗口内容左上角对齐）。
struct WindowDragArea: NSViewRepresentable {
    let onPress: () -> Void
    let onDrag: (CGPoint, CGPoint) -> Void
    /// 拖动是否还在进行（Esc 等取消后为假，之后的拖动和松手都不再生效）。
    let isDragging: () -> Bool
    let onEnd: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> AreaView { AreaView() }

    func updateNSView(_ view: AreaView, context: Context) {
        view.onPress = onPress
        view.onDrag = onDrag
        view.isDragging = isDragging
        view.onEnd = onEnd
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: AreaView, coordinator: ()) {
        view.abandon()
    }

    final class AreaView: NSView {
        var onPress: () -> Void = {}
        var onDrag: (CGPoint, CGPoint) -> Void = { _, _ in }
        var isDragging: () -> Bool = { false }
        var onEnd: () -> Void = {}
        var onCancel: () -> Void = {}
        private var start: CGPoint?
        private var dragging = false

        /// 拖到一半视图被拿掉（面板收起、窗口关闭）时收不到松手，就地取消。
        func abandon() {
            if dragging, isDragging() { onCancel() }
            start = nil
            dragging = false
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { abandon() }
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = location(of: event)
            dragging = false
            onPress()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            if dragging, !isDragging() {
                // 已被取消：这次按下不再拖。
                self.start = nil
                dragging = false
                window?.invalidateCursorRects(for: self)
                return
            }
            let point = location(of: event)
            if !dragging {
                guard hypot(point.x - start.x, point.y - start.y) >= 5 else { return }
                dragging = true
                window?.invalidateCursorRects(for: self)
                NSCursor.closedHand.set()
            }
            onDrag(point, start)
        }

        override func mouseUp(with event: NSEvent) {
            if dragging, isDragging() { onEnd() }
            start = nil
            dragging = false
            window?.invalidateCursorRects(for: self)
        }

        private func location(of event: NSEvent) -> CGPoint {
            guard let content = window?.contentView else { return .zero }
            let point = content.convert(event.locationInWindow, from: nil)
            return content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
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

/// 拖动窗口时：一张小卡跟着指针，落点处浮出松手后的样子；指针到上沿时浮出布局条。
/// 不拖时，布局按钮的五格图上悬停哪一格，也在这里预览。
private struct DragOverlay: View {
    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let drag = layout.drag
        let target = drag?.target ?? (drag == nil ? layout.hoverTarget : nil)
        ZStack(alignment: .topLeading) {
            if let target {
                DropPreview(stack: { if case .stack = target.kind { true } else { false } }())
                    .frame(width: target.rect.width, height: target.rect.height)
                    .position(x: target.rect.midX, y: target.rect.midY)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if let drag, drag.mapOpen {
                LayoutMap(current: layout.locate(drag.windowId)?.panel, layout: layout, hot: drag.target?.panel)
                    .frame(width: PanelLayout.mapSize.width, height: PanelLayout.mapSize.height)
                    .position(x: layout.mapFrame.midX, y: layout.mapFrame.midY)
                    .transition(.opacity.combined(with: .offset(y: -10)))
            }
            if let drag, let window = layout.locate(drag.windowId)?.window {
                DragCard(title: window.content.title(model: model))
                    .scaleEffect(drag.mapOpen ? 0.6 : drag.target != nil ? 0.72 : 1, anchor: UnitPoint(x: drag.grab.x, y: 18 / DragCard.size.height))
                    .opacity(drag.mapOpen ? 0 : drag.target != nil ? 0.5 : 1)
                    .position(cardCenter(drag))
                    .transition(.opacity.combined(with: .scale(scale: 1.3, anchor: UnitPoint(x: drag.grab.x, y: 0))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.1), value: target)
        .animation(.spring(duration: 0.22, bounce: 0.2), value: drag?.mapOpen)
        .animation(.spring(duration: 0.2, bounce: 0.1), value: drag?.target == nil)
        .animation(.easeOut(duration: 0.16), value: drag == nil)
        .allowsHitTesting(false)
    }

    /// 小卡按按下的位置跟手，但不出窗口。
    private func cardCenter(_ drag: WindowDrag) -> CGPoint {
        let size = DragCard.size, bounds = layout.bounds, gap = Metrics.gap
        let x = min(max(drag.location.x - size.width * drag.grab.x, bounds.minX + gap), bounds.maxX - size.width - gap)
        let y = min(max(drag.location.y - drag.grab.y, bounds.minY + gap), bounds.maxY - size.height - gap)
        return CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }
}

/// 落点预览：半透明卡片加一圈强调色。叠放时背后错开露出一张卡边。
private struct DropPreview: View {
    let stack: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
        shape.fill(palette.preview)
            .overlay(shape.strokeBorder(palette.previewRing, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 10)
            .background {
                if stack {
                    shape.fill(palette.card)
                        .overlay(shape.strokeBorder(palette.previewRing, lineWidth: 1))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                        .scaleEffect(0.98)
                        .offset(x: 10, y: -10)
                }
            }
    }
}

/// 跟着指针的小卡：同一个窗口缩小，只留标题和几行示意。
private struct DragCard: View {
    static let size = CGSize(width: 220, height: 140)
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.ink)
                .lineLimit(1)
                .frame(height: 34)
            VStack(alignment: .leading, spacing: 8) {
                ForEach([1, 0.72, 0.84, 0.46], id: \.self) { width in
                    Capsule().fill(palette.ink5).frame(width: (Self.size.width - 24) * width, height: 6)
                }
            }
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .card(palette)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 18)
    }
}

/// 五格布局图：左右是边栏，中间从上到下是顶部、对话、底部。有窗口的格子深一点，当前所在的格子描边。
/// 拖动时作为布局条只显示；放在布局按钮的弹出框里时可以悬停预览、点击移动。
private struct LayoutMap: View {
    let current: PanelID?
    let layout: PanelLayout
    var hot: PanelID?
    var interactive = false
    var onPick: (PanelID) -> Void = { _ in }
    var onHover: (PanelID?) -> Void = { _ in }
    @Environment(\.palette) private var palette
    @State private var hovered: PanelID?

    init(current: PanelID?, layout: PanelLayout, hot: PanelID? = nil) {
        self.current = current
        self.layout = layout
        self.hot = hot
    }

    init(current: PanelID?, layout: PanelLayout, interactive: Bool, onPick: @escaping (PanelID) -> Void, onHover: @escaping (PanelID?) -> Void) {
        self.current = current
        self.layout = layout
        self.interactive = interactive
        self.onPick = onPick
        self.onHover = onHover
    }

    var body: some View {
        let size = PanelLayout.mapSize
        let cells = PanelLayout.mapCells(in: CGRect(origin: .zero, size: size))
        ZStack(alignment: .topLeading) {
            ForEach(PanelID.allCases) { panel in
                if let cell = cells[panel] {
                    let lit = hot == panel || hovered == panel
                    let has = layout.isVisible(panel) && !layout.state(panel).shown.isEmpty
                    RoundedRectangle(cornerRadius: 4)
                        .fill(lit ? palette.accent : has ? palette.ink5 : palette.rowHoverSolid)
                        .overlay {
                            if panel == current {
                                RoundedRectangle(cornerRadius: 4).strokeBorder(palette.ink3, lineWidth: 1.5)
                            }
                        }
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: cell.minX, y: cell.minY)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            guard interactive else { return }
                            hovered = inside ? panel : (hovered == panel ? nil : hovered)
                            onHover(hovered)
                        }
                        .onTapGesture { if interactive { onPick(panel) } }
                        .help(interactive ? panel.title : "")
                        .animation(.easeOut(duration: 0.12), value: lit)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(interactive ? .clear : palette.box, in: .rect(cornerRadius: 10))
        .overlay {
            if !interactive { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.boxStroke, lineWidth: 0.5) }
        }
        .shadow(color: interactive ? .clear : .black.opacity(0.22), radius: 12, y: 8)
    }
}

/// 补位：窗口移走后面板空了，原地列出收着的窗口，点一个补上。
private struct AssistView: View {
    let panel: PanelID
    let layout: PanelLayout
    let model: AppModel
    @Environment(\.palette) private var palette

    var body: some View {
        let hidden = layout.hiddenWindows(in: panel)
        // 卡片固定宽度、整体居中，最多三列。
        let columns = Array(repeating: GridItem(.fixed(200), spacing: 12), count: max(1, min(hidden.count, 3)))
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(hidden) { window in
                AssistCard(title: window.content.title(model: model), detail: detail(window)) {
                    withAnimation(Workbench.settle) { layout.reveal(window.id) }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }

    private func detail(_ window: PanelWindow) -> String {
        switch window.content {
        case .sessions: return "会话列表"
        case .conversation(let id):
            guard let session = model.sessions[id] else { return "" }
            let folder = session.cwd.map { URL(filePath: $0).lastPathComponent } ?? ""
            return [folder, session.updatedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh-Hans")))].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}

private struct AssistCard: View {
    let title: String
    let detail: String
    let pick: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(palette.ink3).lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .topLeading)
            .card(palette)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cardRadius).strokeBorder(palette.previewRing, lineWidth: hovering ? 1.5 : 0)
            }
            .offset(y: hovering ? -2 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.16), value: hovering)
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
