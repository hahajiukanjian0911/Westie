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

struct DropTarget: Equatable {
    var panel: PanelID
    /// 插入到该面板并排窗口中的位置（不计正在拖的窗口）。
    var index: Int
}

struct WindowDrag: Equatable {
    var windowId: UUID
    var location: CGPoint
    var target: DropTarget?
}

/// 一个 Westie 窗口的面板布局：哪个窗口在哪个面板、谁并排显示、谁收着、各面板多大。保存在 UserDefaults。
@MainActor @Observable
final class PanelLayout {
    private(set) var panels: [PanelID: PanelState]
    private(set) var focusedWindowId: UUID?
    private(set) var drag: WindowDrag?

    /// 各面板与窗口在 Workbench 坐标系里的位置，拖放时做命中判断。不参与界面刷新。
    @ObservationIgnored var panelFrames: [PanelID: CGRect] = [:]
    @ObservationIgnored var tileFrames: [UUID: CGRect] = [:]
    @ObservationIgnored var bounds: CGRect = .zero
    /// 最近聚焦的对话窗口：在会话列表里点会话时，在它里面打开。
    @ObservationIgnored private var lastConversationWindowId: UUID?
    @ObservationIgnored private let defaults: UserDefaults

    private static let storageKey = "Westie.panelLayout.v1"

    private struct Saved: Codable {
        var panels: [PanelID: PanelState]
        var focused: UUID?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
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
        panel == .center || (!state(panel).collapsed && !state(panel).shown.isEmpty)
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

    /// 把窗口移到另一个面板（或同一面板的另一个位置），并排显示在 `index` 处。
    func move(_ windowId: UUID, to target: PanelID, at index: Int? = nil) {
        guard let (source, window) = locate(windowId) else { return }
        mutate(source) { state in
            state.windows.removeAll { $0.id == windowId }
            state.shown.removeAll { $0 == windowId }
            state.weights[windowId] = nil
        }
        mutate(target) { state in
            state.windows.append(window)
            state.shown.insert(windowId, at: min(index ?? state.shown.count, state.shown.count))
            state.weights[windowId] = 1
            state.collapsed = false
        }
        focusedWindowId = nil
        focus(windowId)
        save()
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

    func updateDrag(_ windowId: UUID, at location: CGPoint) {
        drag = WindowDrag(windowId: windowId, location: location, target: dropTarget(at: location, dragging: windowId))
    }

    func endDrag() {
        defer { drag = nil }
        guard let drag, let target = drag.target else { return }
        move(drag.windowId, to: target.panel, at: target.index)
    }

    /// 拖动时，不显示的面板在对话面板边缘露出一条落点。
    func dropZones() -> [PanelID: CGRect] {
        guard let center = panelFrames[.center] else { return [:] }
        var zones: [PanelID: CGRect] = [:]
        let thickness: CGFloat = 64
        if !isVisible(.primary) {
            zones[.primary] = CGRect(x: bounds.minX, y: bounds.minY, width: thickness, height: bounds.height)
        }
        if !isVisible(.secondary) {
            zones[.secondary] = CGRect(x: bounds.maxX - thickness, y: bounds.minY, width: thickness, height: bounds.height)
        }
        let inset = center.insetBy(dx: thickness, dy: 0)
        if !isVisible(.top) {
            zones[.top] = CGRect(x: inset.minX, y: center.minY, width: inset.width, height: thickness)
        }
        if !isVisible(.bottom) {
            zones[.bottom] = CGRect(x: inset.minX, y: center.maxY - thickness, width: inset.width, height: thickness)
        }
        return zones
    }

    private func dropTarget(at point: CGPoint, dragging windowId: UUID) -> DropTarget? {
        for (panel, zone) in dropZones() where zone.contains(point) {
            return DropTarget(panel: panel, index: state(panel).shown.filter { $0 != windowId }.count)
        }
        for panel in PanelID.allCases where isVisible(panel) {
            guard let frame = panelFrames[panel], frame.contains(point) else { continue }
            let before = state(panel).shown.filter { $0 != windowId }.filter { id in
                guard let tile = tileFrames[id] else { return false }
                return panel.isHorizontal ? tile.midX < point.x : tile.midY < point.y
            }
            return DropTarget(panel: panel, index: before.count)
        }
        return nil
    }

    /// 落点提示的位置：插入处的一条线，空面板则整块高亮。
    func indicatorFrame(for target: DropTarget, dragging windowId: UUID) -> CGRect? {
        if let zone = dropZones()[target.panel] { return zone }
        guard let frame = panelFrames[target.panel] else { return nil }
        let others = state(target.panel).shown.filter { $0 != windowId }.compactMap { tileFrames[$0] }
        guard !others.isEmpty else { return frame }
        let horizontal = target.panel.isHorizontal
        let edge: CGFloat = target.index < others.count
            ? (horizontal ? others[target.index].minX : others[target.index].minY)
            : (horizontal ? others[others.count - 1].maxX : others[others.count - 1].maxY)
        return horizontal
            ? CGRect(x: edge - 2, y: frame.minY, width: 4, height: frame.height)
            : CGRect(x: frame.minX, y: edge - 2, width: frame.width, height: 4)
    }

    // MARK: - 保存

    private func mutate(_ panel: PanelID, _ change: (inout PanelState) -> Void) {
        var state = state(panel)
        change(&state)
        panels[panel] = state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(Saved(panels: panels, focused: focusedWindowId)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
