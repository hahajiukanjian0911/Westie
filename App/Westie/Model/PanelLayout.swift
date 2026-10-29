import CoreGraphics
import Foundation
import Observation

/// 窗口里固定的五个面板，彼此平级：只管位置、尺寸、收起，以及里面的窗口怎么摆。
enum PanelID: String, Codable, CaseIterable, Identifiable {
    case top, primary, center, secondary, bottom

    var id: Self { self }

    var title: String {
        switch self {
        case .top: "顶部面板"
        case .primary: "主边栏"
        case .center: "对话面板"
        case .secondary: "侧边栏"
        case .bottom: "底部面板"
        }
    }

    /// 窗口在面板里的并排方向：宽面板左右并排，窄面板上下叠放。
    var isHorizontal: Bool { self == .top || self == .center || self == .bottom }

    /// 面板尺寸（边栏是宽度，顶部底部是高度）的范围。
    var sizeRange: ClosedRange<Double> { isHorizontal ? 80...600 : 180...600 }
}

/// 窗口装的内容。窗口是最小单位，自己不再切分；并排由面板负责。
enum WindowContent: Codable, Hashable {
    case sessions
    case conversation(sessionId: String)

    var sessionId: String? {
        if case .conversation(let id) = self { id } else { nil }
    }
}

struct PanelWindow: Identifiable, Codable, Hashable {
    var id = UUID()
    var content: WindowContent
}

struct PanelState: Codable, Equatable {
    /// 面板里的全部窗口；不在 `shown` 里的就是收着的，随时可以切出来。
    var windows: [PanelWindow] = []
    /// 并排显示的窗口，按显示顺序。
    var shown: [UUID] = []
    /// 并排时各窗口的占比。
    var weights: [UUID: Double] = [:]
    var collapsed = false
    var size: Double

    func window(_ id: UUID) -> PanelWindow? { windows.first { $0.id == id } }
}

/// 松手后窗口会落在哪里。`rect` 就是落下后的样子，用来画预览。
struct DropTarget: Equatable {
    enum Kind: Equatable {
        /// 面板里还没有别的窗口：占满整个面板（没显示的面板按展开后的大小）。
        case panel
        /// 并排插在某个窗口前面或后面，预览占那个窗口的一半。
        case half
        /// 叠进某个窗口的位置，原窗口收着。
        case stack(on: UUID)
    }

    var panel: PanelID
    /// 插入到该面板并排窗口中的位置（不计正在拖的窗口）。
    var index: Int
    var kind: Kind
    var rect: CGRect
}

struct WindowDrag: Equatable {
    var windowId: UUID
    var location: CGPoint
    /// 指针按在标题栏的哪里：横向是占窗口宽度的比例，纵向是离顶边的距离。拖动卡按它跟手。
    var grab: CGPoint
    var target: DropTarget?
    /// 指针到过对话面板上沿，布局条正打开着。
    var mapOpen = false
    /// 正停在哪条外圈上、从什么时候开始停的。
    var band: (panel: PanelID, since: Date)?

    static func == (a: Self, b: Self) -> Bool {
        a.windowId == b.windowId && a.location == b.location && a.grab == b.grab && a.target == b.target
            && a.mapOpen == b.mapOpen && a.band?.panel == b.band?.panel
    }
}

/// 一个 Westie 窗口的面板布局：哪个窗口在哪个面板、谁并排显示、谁收着、各面板多大。保存在 UserDefaults。
@MainActor @Observable
final class PanelLayout {
    private(set) var panels: [PanelID: PanelState]
    private(set) var focusedWindowId: UUID?
    private(set) var drag: WindowDrag?
    /// 布局按钮的五格图上悬停的格子对应的落点，只用来画预览。
    var hoverTarget: DropTarget?
    #if DEBUG
    /// 自动化截图用：所有窗口的拖动条常亮。
    var gripsShown = false
    #endif
    /// 窗口移走后空出来、正在请你挑一个收着的窗口补上的面板。
    private(set) var assisting: Set<PanelID> = []

    /// 各面板与窗口在 Workbench 坐标系里的位置，拖放时做命中判断。不参与界面刷新。
    @ObservationIgnored var panelFrames: [PanelID: CGRect] = [:]
    @ObservationIgnored var tileFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero
    /// 最近聚焦的对话窗口：在会话列表里点会话时，在它里面打开。
    @ObservationIgnored private var lastConversationWindowId: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var dwellTask: Task<Void, Never>?

    /// 布局里的对话窗口指向某份数据里的会话，所以按数据目录分开保存：真实 `~/.dsh` 沿用原来的键，
    /// 假模型或另指的测试数据各用各的，互相恢复不出对方的会话窗口。
    @ObservationIgnored private let storageKey: String

    private struct Saved: Codable {
        var panels: [PanelID: PanelState]
        var focused: UUID?
    }

    init(defaults: UserDefaults = .standard, dataScope: String? = nil) {
        self.defaults = defaults
        storageKey = "Westie.panelLayout.v1" + (dataScope.map { ".\($0)" } ?? "")
        let saved = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        var panels = saved?.panels ?? Self.defaultPanels
        for id in PanelID.allCases where panels[id] == nil { panels[id] = Self.defaultPanels[id] }
        self.panels = panels
        focusedWindowId = saved?.focused
    }

    static var defaultPanels: [PanelID: PanelState] {
        let sessions = PanelWindow(content: .sessions)
        return [
            .top: PanelState(size: 120),
            .primary: PanelState(windows: [sessions], shown: [sessions.id], weights: [sessions.id: 1], size: 260),
            .center: PanelState(size: 0),
            .secondary: PanelState(size: 320),
            .bottom: PanelState(size: 220),
        ]
    }

    // MARK: - 读取

    func state(_ panel: PanelID) -> PanelState { panels[panel] ?? PanelState(size: 0) }

    func shownWindows(in panel: PanelID) -> [PanelWindow] {
        let state = state(panel)
        return state.shown.compactMap(state.window)
    }

    func hiddenWindows(in panel: PanelID) -> [PanelWindow] {
        let state = state(panel)
        return state.windows.filter { !state.shown.contains($0.id) }
    }

    /// 对话面板始终在；其余面板收起或没有并排显示的窗口时不占位置。
    func isVisible(_ panel: PanelID) -> Bool {
        panel == .center || (!state(panel).collapsed && (!state(panel).shown.isEmpty || assisting.contains(panel)))
    }

    func canToggle(_ panel: PanelID) -> Bool { panel != .center && !state(panel).windows.isEmpty }

    func weight(of windowId: UUID, in panel: PanelID) -> Double { state(panel).weights[windowId] ?? 1 }

    func locate(_ windowId: UUID) -> (panel: PanelID, window: PanelWindow)? {
        for panel in PanelID.allCases {
            if let window = state(panel).window(windowId) { return (panel, window) }
        }
        return nil
    }

    private func locate(_ content: WindowContent) -> (panel: PanelID, window: PanelWindow)? {
        for panel in PanelID.allCases {
            if let window = state(panel).windows.first(where: { $0.content == content }) { return (panel, window) }
        }
        return nil
    }

    var focusedSessionId: String? { focusedWindowId.flatMap { locate($0)?.window.content.sessionId } }

    /// 正在显示的会话：只有它们需要跟读。
    var visibleSessionIds: Set<String> {
        Set(PanelID.allCases.filter(isVisible).flatMap(shownWindows).compactMap(\.content.sessionId))
    }

    // MARK: - 面板

    func toggle(_ panel: PanelID) {
        guard canToggle(panel) else { return }
        dismissAssist()
        mutate(panel) { state in
            state.collapsed.toggle()
            if !state.collapsed, state.shown.isEmpty, let first = state.windows.first {
                state.shown = [first.id]
            }
        }
        save()
    }

    func setSize(_ size: Double, of panel: PanelID) {
        mutate(panel) { $0.size = min(max(size, panel.sizeRange.lowerBound), panel.sizeRange.upperBound) }
    }

    func setWeights(_ weights: [UUID: Double], in panel: PanelID) {
        mutate(panel) { $0.weights.merge(weights) { $1 } }
    }

    // MARK: - 窗口

    func focus(_ windowId: UUID) {
        dismissAssist()
        guard focusedWindowId != windowId else { return }
        focusedWindowId = windowId
        if locate(windowId)?.window.content.sessionId != nil { lastConversationWindowId = windowId }
        save()
    }

    /// 把收着的窗口切出来，替换掉该面板里当前聚焦（或最后一个）的并排窗口。
    func reveal(_ windowId: UUID) {
        guard let (panel, _) = locate(windowId) else { return }
        let focused = focusedWindowId
        mutate(panel) { state in
            state.collapsed = false
            guard !state.shown.contains(windowId) else { return }
            let slot = focused.flatMap { state.shown.firstIndex(of: $0) } ?? state.shown.indices.last
            if let slot {
                state.weights[windowId] = state.weights[state.shown[slot]] ?? 1
                state.shown[slot] = windowId
            } else {
                state.shown = [windowId]
                state.weights[windowId] = 1
            }
        }
        focus(windowId)
        save()
    }

    /// 把收着的窗口加入并排。
    func showSideBySide(_ windowId: UUID) {
        guard let (panel, _) = locate(windowId) else { return }
        mutate(panel) { state in
            state.collapsed = false
            guard !state.shown.contains(windowId) else { return }
            state.shown.append(windowId)
            state.weights[windowId] = 1
        }
        focus(windowId)
        save()
    }

    /// 收起窗口：从并排里拿掉，仍留在面板里。
    func hide(_ windowId: UUID) {
        guard let (panel, _) = locate(windowId) else { return }
        mutate(panel) { $0.shown.removeAll { $0 == windowId } }
        refocus(after: windowId, in: panel)
        save()
    }

    func close(_ windowId: UUID) {
        guard let (panel, _) = locate(windowId) else { return }
        mutate(panel) { state in
            state.windows.removeAll { $0.id == windowId }
            state.shown.removeAll { $0 == windowId }
            state.weights[windowId] = nil
        }
        refocus(after: windowId, in: panel)
        save()
    }

    /// 把窗口移到另一个面板（或同一面板的另一个位置），并排显示在 `index` 处；
    /// 给了 `replacing` 就叠进那个窗口的位置，那个窗口收着。
    /// 原面板因此空了、但还有收着的窗口时，原地列出它们请你挑一个补上。
    func move(_ windowId: UUID, to target: PanelID, at index: Int? = nil, replacing other: UUID? = nil) {
        guard let (source, window) = locate(windowId) else { return }
        dismissAssist()
        let weight = state(source).weights[windowId]
        mutate(source) { state in
            state.windows.removeAll { $0.id == windowId }
            state.shown.removeAll { $0 == windowId }
            state.weights[windowId] = nil
        }
        mutate(target) { state in
            state.windows.append(window)
            if let other, let slot = state.shown.firstIndex(of: other) {
                state.shown[slot] = windowId
                state.weights[windowId] = state.weights[other] ?? 1
            } else {
                state.shown.insert(windowId, at: min(index ?? state.shown.count, state.shown.count))
                state.weights[windowId] = source == target ? weight ?? 1 : 1
            }
            state.collapsed = false
        }
        focusedWindowId = nil
        focus(windowId)
        if source != target, state(source).shown.isEmpty, !state(source).windows.isEmpty, !state(source).collapsed {
            assisting.insert(source)
        }
        save()
    }

    func dismissAssist() {
        if !assisting.isEmpty { assisting = [] }
    }

    /// 会话列表被关掉后从菜单找回来。
    func showSessions() {
        if let (_, window) = locate(.sessions) {
            reveal(window.id)
        } else {
            let window = PanelWindow(content: .sessions)
            mutate(.primary) { $0.windows.insert(window, at: 0) }
            showSideBySide(window.id)
        }
    }

    enum OpenMode { case navigate, newWindow, sideBySide }

    /// 打开会话。已经在某个窗口里就切到那个窗口；否则：
    /// `navigate` 在最近聚焦的对话窗口里换成这个会话，`newWindow` 开新窗口替换它的位置，`sideBySide` 开新窗口并排。
    func openConversation(_ sessionId: String, mode: OpenMode = .navigate) {
        let content = WindowContent.conversation(sessionId: sessionId)
        if let (_, window) = locate(content) {
            if mode == .sideBySide { showSideBySide(window.id) } else { reveal(window.id) }
            return
        }
        let anchor = conversationAnchor()
        if mode == .navigate, let (panel, window) = anchor {
            mutate(panel) { state in
                if let index = state.windows.firstIndex(where: { $0.id == window.id }) { state.windows[index].content = content }
            }
            focusedWindowId = nil
            focus(window.id)
            return
        }
        let panel = anchor?.panel ?? .center
        let window = PanelWindow(content: content)
        mutate(panel) { $0.windows.append(window) }
        if mode == .sideBySide { showSideBySide(window.id) } else { reveal(window.id) }
    }

    /// 最近聚焦且正在显示的对话窗口；没有就取对话面板里第一个显示的对话窗口。
    private func conversationAnchor() -> (panel: PanelID, window: PanelWindow)? {
        for candidate in [focusedWindowId, lastConversationWindowId].compactMap({ $0 }) {
            if let found = locate(candidate), found.window.content.sessionId != nil,
               isVisible(found.panel), state(found.panel).shown.contains(candidate) {
                return found
            }
        }
        return shownWindows(in: .center).first { $0.content.sessionId != nil }.map { (.center, $0) }
    }

    private func refocus(after windowId: UUID, in panel: PanelID) {
        guard focusedWindowId == windowId else { return }
        focusedWindowId = nil
        if let next = state(panel).shown.first ?? state(.center).shown.first { focus(next) }
    }

    // MARK: - 拖放
    //
    // 拖动时布局不动，只有一张小卡跟着指针，落点用松手后的样子预览：
    // 外框最外一圈 → 那条边上没显示的面板（停一下才算）；对话面板上沿 → 布局条；
    // 窗口卡片的前三成 / 后三成 → 并排插在它前面 / 后面；正中间 → 叠进去。

    static let bandWidth: CGFloat = 24
    static let dwell: TimeInterval = 0.15
    static let mapSize = CGSize(width: 132, height: 76)

    func updateDrag(_ windowId: UUID, at location: CGPoint, from start: CGPoint) {
        if drag?.windowId != windowId {
            dismissAssist()
            hoverTarget = nil
            let tile = tileFrames[windowId] ?? CGRect(origin: start, size: CGSize(width: 1, height: 1))
            let grab = CGPoint(x: min(max((start.x - tile.minX) / max(tile.width, 1), 0), 1), y: min(max(start.y - tile.minY, 0), 22))
            drag = WindowDrag(windowId: windowId, location: location, grab: grab)
        }
        guard var drag else { return }
        drag.location = location
        resolve(&drag)
        self.drag = drag
    }

    func endDrag() {
        dwellTask?.cancel()
        defer { drag = nil }
        guard let drag, let target = drag.target else { return }
        if case .stack(let other) = target.kind {
            move(drag.windowId, to: target.panel, replacing: other)
        } else {
            move(drag.windowId, to: target.panel, at: target.index)
        }
    }

    func cancelDrag() {
        dwellTask?.cancel()
        drag = nil
    }

    private func resolve(_ drag: inout WindowDrag) {
        let point = drag.location, id = drag.windowId
        let center = panelFrames[.center] ?? bounds
        var target: DropTarget?

        // 上沿：布局条。离开它附近就收回去。
        let nearTop = point.y < bounds.minY + 16 && point.x > center.minX && point.x < center.maxX
        if nearTop { drag.mapOpen = true }
        if drag.mapOpen {
            let map = mapFrame
            let keep = CGRect(x: map.minX - 32, y: bounds.minY - 40, width: map.width + 64, height: map.maxY + 28 - (bounds.minY - 40))
            if nearTop || keep.contains(point) {
                let cells = Self.mapCells(in: map)
                target = cells.first { $0.value.contains(point) }.map { appendTarget($0.key, dragging: id) }
            } else {
                drag.mapOpen = false
            }
        }

        // 外圈：没显示的面板，停一下才算。
        var waiting = false
        if target == nil, !drag.mapOpen {
            if let hit = bands().first(where: { $0.value.contains(point) })?.key {
                if drag.band?.panel != hit {
                    drag.band = (hit, Date())
                    scheduleDwell()
                }
                if let band = drag.band, Date().timeIntervalSince(band.since) >= Self.dwell {
                    target = DropTarget(panel: hit, index: 0, kind: .panel, rect: landRect(hit))
                } else {
                    waiting = true
                }
            } else {
                drag.band = nil
            }
        }

        // 窗口卡片上。
        if target == nil, !waiting, !drag.mapOpen {
            for panel in PanelID.allCases where isVisible(panel) {
                guard let frame = panelFrames[panel], frame.contains(point) else { continue }
                target = cardTarget(panel, at: point, frame: frame, dragging: id)
                break
            }
        }
        drag.target = target
    }

    /// 停在外圈上时，过了停留时间再判一次，指针不动也能出预览。
    private func scheduleDwell() {
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dwell + 0.01))
            guard !Task.isCancelled, let self, var drag = self.drag else { return }
            self.resolve(&drag)
            self.drag = drag
        }
    }

    /// 外框最外一圈里，对应那条边上还没显示的面板。顶部面板走布局条。
    func bands() -> [PanelID: CGRect] {
        var bands: [PanelID: CGRect] = [:]
        let b = bounds, w = Self.bandWidth, top = Metrics.lightsHeight
        if !isVisible(.primary) { bands[.primary] = CGRect(x: b.minX, y: b.minY + top, width: w, height: b.height - top) }
        if !isVisible(.secondary) { bands[.secondary] = CGRect(x: b.maxX - w, y: b.minY + top, width: w, height: b.height - top) }
        if !isVisible(.bottom) { bands[.bottom] = CGRect(x: b.minX + w, y: b.maxY - w, width: b.width - 2 * w, height: w) }
        return bands
    }

    /// 没显示的面板展开后的位置。
    private func landRect(_ panel: PanelID) -> CGRect {
        let b = bounds, gap = Metrics.gap, size = state(panel).size
        let center = panelFrames[.center] ?? b
        switch panel {
        case .primary: return CGRect(x: b.minX + gap, y: b.minY + Metrics.lightsHeight, width: size, height: b.height - Metrics.lightsHeight - gap)
        case .secondary: return CGRect(x: b.maxX - gap - size, y: b.minY + gap, width: size, height: b.height - 2 * gap)
        case .top: return CGRect(x: center.minX, y: center.minY, width: center.width, height: size)
        case .bottom: return CGRect(x: center.minX, y: center.maxY - size, width: center.width, height: size)
        case .center: return center
        }
    }

    /// 停在某个面板里：按指针落在哪个窗口、窗口的哪一段决定并排还是叠放。
    private func cardTarget(_ panel: PanelID, at point: CGPoint, frame: CGRect, dragging id: UUID) -> DropTarget? {
        let shown = state(panel).shown
        let others = shown.filter { $0 != id }
        guard !others.isEmpty else { return DropTarget(panel: panel, index: 0, kind: .panel, rect: frame) }
        let tiles = shown.compactMap { tile in tileFrames[tile].map { (tile, $0) } }
        guard let hit = tiles.first(where: { $0.1.contains(point) })
            ?? tiles.min(by: { Self.distance($0.1, point) < Self.distance($1.1, point) })
        else { return nil }
        // 放回自己身上：不动。
        if hit.0 == id { return nil }
        let horizontal = panel.isHorizontal, rect = hit.1
        let fraction = horizontal ? (point.x - rect.minX) / rect.width : (point.y - rect.minY) / rect.height
        let index = others.firstIndex(of: hit.0) ?? others.count
        if fraction < 0.3 { return DropTarget(panel: panel, index: index, kind: .half, rect: Self.half(rect, horizontal: horizontal, first: true)) }
        if fraction > 0.7 { return DropTarget(panel: panel, index: index + 1, kind: .half, rect: Self.half(rect, horizontal: horizontal, first: false)) }
        return DropTarget(panel: panel, index: index, kind: .stack(on: hit.0), rect: rect)
    }

    /// 放到某个面板的最后：没显示就是展开后的整条，显示着就占最后一个窗口的后一半。
    func appendTarget(_ panel: PanelID, dragging id: UUID) -> DropTarget {
        let others = state(panel).shown.filter { $0 != id }
        if !isVisible(panel) || (panel != .center && state(panel).shown.isEmpty) {
            return DropTarget(panel: panel, index: 0, kind: .panel, rect: landRect(panel))
        }
        guard let last = others.last.flatMap({ tileFrames[$0] }) else {
            return DropTarget(panel: panel, index: 0, kind: .panel, rect: panelFrames[panel] ?? landRect(panel))
        }
        return DropTarget(panel: panel, index: others.count, kind: .half, rect: Self.half(last, horizontal: panel.isHorizontal, first: false))
    }

    /// 布局条在对话面板正上方、离窗口顶边 12pt。
    var mapFrame: CGRect {
        let center = panelFrames[.center] ?? bounds
        return CGRect(x: center.midX - Self.mapSize.width / 2, y: bounds.minY + 12, width: Self.mapSize.width, height: Self.mapSize.height)
    }

    /// 五格布局图里每个面板的格子：左右两列是边栏，中间一列从上到下是顶部、对话、底部。
    static func mapCells(in rect: CGRect) -> [PanelID: CGRect] {
        let inner = rect.insetBy(dx: 4, dy: 4), gap: CGFloat = 3, column: CGFloat = 26, band: CGFloat = 15
        let middle = CGRect(x: inner.minX + column + gap, y: inner.minY, width: inner.width - 2 * (column + gap), height: inner.height)
        return [
            .primary: CGRect(x: inner.minX, y: inner.minY, width: column, height: inner.height),
            .secondary: CGRect(x: inner.maxX - column, y: inner.minY, width: column, height: inner.height),
            .top: CGRect(x: middle.minX, y: middle.minY, width: middle.width, height: band),
            .center: CGRect(x: middle.minX, y: middle.minY + band + gap, width: middle.width, height: middle.height - 2 * (band + gap)),
            .bottom: CGRect(x: middle.minX, y: middle.maxY - band, width: middle.width, height: band),
        ]
    }

    private static func half(_ rect: CGRect, horizontal: Bool, first: Bool) -> CGRect {
        let gap = Metrics.gap / 2
        return horizontal
            ? CGRect(x: first ? rect.minX : rect.midX + gap, y: rect.minY, width: rect.width / 2 - gap, height: rect.height)
            : CGRect(x: rect.minX, y: first ? rect.minY : rect.midY + gap, width: rect.width, height: rect.height / 2 - gap)
    }

    private static func distance(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    // MARK: - 保存

    private func mutate(_ panel: PanelID, _ change: (inout PanelState) -> Void) {
        var state = state(panel)
        change(&state)
        panels[panel] = state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(Saved(panels: panels, focused: focusedWindowId)) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
