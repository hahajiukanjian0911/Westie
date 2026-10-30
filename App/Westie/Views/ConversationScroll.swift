import AppKit
import SwiftUI
import WestieKit

/// 对话列表的滚动宿主：AppKit 的 NSScrollView 包着 SwiftUI 内容，滚动位置只由 ConversationScroller 一处决定。
///
/// SwiftUI 的 ScrollView 会在内容尺寸变化时自行调整偏移，展开、收起、删卡片都可能把正在看的内容带走
/// （见 shared/skills/motion-pitfalls/patterns/scroll-anchor-loss.md）。这里偏移只在三种情况下变：
/// 用户自己滚、跟随底部、加载更早历史时补偿新插入的高度。其余任何高度变化都不动偏移；
/// 内容变短时文档高度至少留到“当前偏移 + 视口”，偏移不会被夹回，看着的东西就不会跳。
/// 每块拥有自己的 SwiftUI 布局图；高度/局部行坐标留在 AppKit，后续可用等高占位替换视图。
struct ConversationChunk<Content: View & Equatable>: Identifiable {
    let id: String
    let content: Content
}

struct ConversationChunkGeometry: Equatable {
    var height: CGFloat = 0
    var targetHeight: CGFloat = 0
    var width: CGFloat = 0
    var rows: [String: CGFloat] = [:]
    var ready = true

    func matches(_ other: Self) -> Bool {
        // 移动宿主后锚点换算可能留下浮点舍入尾数，不能把它反馈成新一轮布局。
        abs(height - other.height) < 0.000_001 && abs(targetHeight - other.targetHeight) < 0.000_001
            && abs(width - other.width) < 0.000_001 && ready == other.ready
            && rows.count == other.rows.count
            && rows.allSatisfy { id, y in other.rows[id].map { abs($0 - y) < 0.000_001 } == true }
    }
}

struct ConversationChunkReady: PreferenceKey {
    static var defaultValue: Bool { true }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() && value }
}

struct ConversationChunkRows: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct ChunkGeometryKey: PreferenceKey {
    static var defaultValue: ConversationChunkGeometry { .init() }
    static func reduce(value: inout ConversationChunkGeometry, nextValue: () -> ConversationChunkGeometry) {
        let next = nextValue()
        value.height = max(value.height, next.height)
        value.targetHeight = max(value.targetHeight, next.targetHeight)
        value.width = max(value.width, next.width)
        value.rows.merge(next.rows, uniquingKeysWith: { _, next in next })
        value.ready = value.ready && next.ready
    }
}

private struct ChunkBottomKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private struct MeasuredChunk<Content: View>: View {
    let content: Content
    let measured: (ConversationChunkGeometry) -> Void

    var body: some View {
        ChunkTopAligned {
            VStack(spacing: 0) {
                content
                Color.clear.frame(height: 0)
                    .anchorPreference(key: ChunkBottomKey.self, value: .bounds) { $0 }
            }
                .backgroundPreferenceValue(ChunkBottomKey.self) { bottom in
                    GeometryReader { proxy in
                        Color.clear.preference(key: ChunkGeometryKey.self, value: .init(
                            height: bottom.map { proxy[$0].minY } ?? 0))
                    }
                }
                .backgroundPreferenceValue(ConversationChunkRows.self) { anchors in
                    GeometryReader { proxy in
                        Color.clear.preference(key: ChunkGeometryKey.self, value: .init(
                            targetHeight: proxy.size.height, width: proxy.size.width,
                            rows: anchors.mapValues { proxy[$0].minY }))
                    }
                }
                .backgroundPreferenceValue(ConversationChunkReady.self) { ready in
                    Color.clear.preference(key: ChunkGeometryKey.self, value: .init(ready: ready))
                }
                .onPreferenceChange(ChunkGeometryKey.self, perform: measured)
        }
    }
}

/// 宿主给定缓存高度，内部始终用理想高度贴顶排；新高度在同一次 AppKit 布局里提交。
private struct ChunkTopAligned: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: bounds.width, height: nil))
        }
    }
}

struct ConversationScroll<Content: View & Equatable>: NSViewRepresentable {
    let scroller: ConversationScroller
    let chunks: [ConversationChunk<Content>]
    let firstSeq: Int?
    let lastUserId: String?
    let columnWidth: CGFloat?
    let loaded: Bool
    var onReady: () -> Void

    func makeNSView(context: Context) -> ConversationScrollView {
        let scrollView = ConversationScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        let document = ConversationChunkDocument<Content>()
        document.scroller = scroller
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scroller.attach(scrollView: scrollView, document: document)
        return scrollView
    }

    func updateNSView(_ scrollView: ConversationScrollView, context: Context) {
        PerfTrace.count("hosting_update")
        (scrollView.documentView as? ConversationChunkDocument<Content>)?.update(
            chunks, firstSeq: firstSeq, lastUserId: lastUserId, columnWidth: columnWidth,
            loaded: loaded, onReady: onReady)
    }

    // 这里是由外层分配尺寸的视口；文档的自然高度不能参与 SwiftUI 对视口的尺寸探测。
    // 否则默认 fittingSize 会遍历全部轮的 Auto Layout 子树，流式时仍随历史长度增长。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationScrollView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: nsView.frame.size)
        return CGSize(width: size.width.isFinite ? size.width : nsView.frame.width,
                      height: size.height.isFinite ? size.height : nsView.frame.height)
    }

    static func dismantleNSView(_ scrollView: ConversationScrollView, coordinator: ()) {
        scrollView.scroller?.detach()
        scrollView.documentView = nil
    }
}

/// 一次创建全部轮。只测新增块/宽度改变的块；内部流式或展开直接报告本块高度，不重测历史。
final class ConversationChunkDocument<Content: View & Equatable>: NSView {
    override var isFlipped: Bool { true }
    weak var scroller: ConversationScroller?

    @MainActor private final class Entry {
        let id: String
        var content: Content
        let hosting: NSHostingView<MeasuredChunk<Content>>
        var geometry = ConversationChunkGeometry()
        var hasMeasurement = false
        init(id: String, content: Content, measured: @escaping (ConversationChunkGeometry) -> Void) {
            self.id = id
            self.content = content
            hosting = NSHostingView(rootView: MeasuredChunk(content: content, measured: measured))
            hosting.sizingOptions = []
            hosting.safeAreaRegions = []
        }
    }
    private var entries: [Entry] = []
    private var byId: [String: Entry] = [:]
    private var firstSeq: Int?
    private var lastUserId: String?
    private var columnWidth: CGFloat?
    private var measuredWidth: CGFloat = -1
    private var updating = false
    private var dirty = false
    private var revision = 0
    private var loaded = false
    private var presented = false
    private var onReady: (() -> Void)?

    func update(_ chunks: [ConversationChunk<Content>], firstSeq: Int?, lastUserId: String?, columnWidth: CGFloat?,
                loaded: Bool = true, onReady: (() -> Void)? = nil) {
        updating = true
        self.loaded = loaded
        self.onReady = onReady
        self.firstSeq = firstSeq
        self.lastUserId = lastUserId
        self.columnWidth = columnWidth
        let ids = Set(chunks.map(\.id))
        for entry in entries where !ids.contains(entry.id) {
            entry.hosting.removeFromSuperview()
            byId[entry.id] = nil
        }
        entries = chunks.map { chunk in
            if let entry = byId[chunk.id] {
                if entry.content != chunk.content {
                    entry.content = chunk.content
                    entry.hosting.rootView = root(for: chunk)
                    PerfTrace.count("hosting_root_replace")
                }
                return entry
            }
            let entry = Entry(id: chunk.id, content: chunk.content) { [weak self] value in self?.measured(chunk.id, value) }
            byId[chunk.id] = entry
            addSubview(entry.hosting)
            return entry
        }
        measureNewOrResized()
        updating = false
        dirty = true
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func root(for chunk: ConversationChunk<Content>) -> MeasuredChunk<Content> {
        MeasuredChunk(content: chunk.content) { [weak self] value in self?.measured(chunk.id, value) }
    }

    private func measured(_ id: String, _ value: ConversationChunkGeometry) {
        guard let entry = byId[id], value.height.isFinite, value.height >= 0,
              abs(entry.hosting.frame.width - value.width) < 0.01, value.width > 0,
              (!entry.hasMeasurement || !entry.geometry.matches(value)) else { return }
        #if DEBUG
        trace("chunk \(id) width \(entry.hosting.frame.width) height \(value.height) target \(value.targetHeight) ready \(value.ready) rows \(value.rows)")
        #endif
        entry.geometry = value
        entry.hasMeasurement = true
        revision += 1
        PerfTrace.count("chunk_geometry")
        dirty = true
        needsLayout = true
    }

    private func measureNewOrResized() {
        let available = max(0, bounds.width - 48)
        let width = min(available, columnWidth ?? available)
        guard width > 0 else { return }
        for entry in entries where measuredWidth != width || entry.hosting.frame.width == 0 {
            PerfTrace.count("chunk_measure")
            entry.hasMeasurement = false
            entry.hosting.setFrameSize(CGSize(width: width, height: entry.geometry.height))
            entry.hosting.layoutSubtreeIfNeeded()
        }
        measuredWidth = width
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        if changed { dirty = true; needsLayout = true }
    }

    override func layout() {
        super.layout()
        guard !updating else { return }
        updating = true
        measureNewOrResized()
        // 初次快照必须完整测完才发布；局部高度0不能被当作“已到顶”自动翻页。
        guard dirty, entries.allSatisfy(\.hasMeasurement) else { updating = false; return }
        let latest = placeEntries()
        dirty = false
        updating = false
        let complete = entries.allSatisfy({ $0.geometry.ready && abs($0.geometry.height - $0.geometry.targetHeight) < 1 })
        // 就绪之前不滚离正在解析的内容；也不把空/中间快照当成真实历史发布。
        guard presented || (loaded && complete) else { return }
        scroller?.layoutChanged(latest)
        if !presented {
            presented = true
            scroller?.presentInitialLayout()
            PerfTrace.count("conversation_layout_presented")
            #if DEBUG
            trace("present revision \(revision) end \(latest.end)")
            #endif
            if let onReady { DispatchQueue.main.async { onReady() } }
        }
    }

    private func placeEntries() -> ConversationGeometry {
        var y: CGFloat = 8
        var rows: [String: CGFloat] = [:]
        for (index, entry) in entries.enumerated() {
            let next = CGRect(x: (bounds.width - measuredWidth) / 2, y: y, width: max(0, measuredWidth), height: entry.geometry.height)
            if entry.hosting.frame != next {
                entry.hosting.frame = next
                PerfTrace.count("chunk_place")
            }
            for (id, local) in entry.geometry.rows { rows[id] = y + local }
            y += entry.geometry.height
            if index < entries.count - 1 { y += 16 }
        }
        return .init(end: y, firstSeq: firstSeq, lastUserId: lastUserId, rows: rows)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }

}

/// 只多做一件事：分辨“用户自己在滚”，滚轮、触控板和拖滚动条都算。
final class ConversationScrollView: NSScrollView {
    weak var scroller: ConversationScroller?

    override func scrollWheel(with event: NSEvent) {
        scroller?.userScrollBegan()
        super.scrollWheel(with: event)
        // 触控板手势（含惯性）由 live scroll 通知收尾；老式滚轮一格一格，没有阶段
        if event.phase.isEmpty, event.momentumPhase.isEmpty { scroller?.userScrollEnded() }
    }
}

/// 一次布局提交的测量。分页按同一存活行的坐标差补偿，不能拿总高度差（其中可能混有尾部流式增长）。
struct ConversationGeometry: Equatable {
    var end: CGFloat
    var firstSeq: Int?
    var lastUserId: String?
    var rows: [String: CGFloat]
}

/// 对话滚动的唯一协调者。设计稿 2026-10-29-chat-scroll v1：
/// - 内容从上往下排；底部留白（turnSpace）刚好够最后一条用户消息顶到窗口上方 16pt，回复越长留白越小。
/// - “跟随”就是贴住文档底部：留白还在时底部正是那条消息顶到上方的位置，回复变长、留白缩小，文档总高不变，画面不动；
///   留白用完后文档变高，跟着往下走。跟随只往下走，不往回拉。
/// - 用户点开、收起、往上翻：停止跟随，偏移原地不动。
@MainActor final class ConversationScroller {
    static let anchorMargin: CGFloat = 16
    static let bottomPadding: CGFloat = 24

    struct Metrics: Equatable {
        var offset: CGFloat
        var viewport: CGFloat
        /// 真实内容（不含留白）底部离视口底部还有多远。
        var distanceToEnd: CGFloat
    }

    /// 滚动状态变了（偏移、视口、内容）。
    var onMetrics: ((Metrics) -> Void)?
    /// 空宿主的 offset=0 不能拿来判断是否该翻历史；等当前快照真正排版后再判断。
    var hasMeasuredHistory: Bool { geometry?.firstSeq != nil }

    func refreshMetrics() { apply() }

    private weak var scrollView: ConversationScrollView?
    private weak var document: NSView?
    private var observers: [NSObjectProtocol] = []

    /// SwiftUI 内容量到的：内容底部、最后一条用户消息顶部（都在文档坐标里）。
    private var contentEnd: CGFloat = 0
    private var lastUserY: CGFloat?
    private var lastUserId: String?
    private(set) var following = true
    /// 刚发出、还没量到位置的那条消息：量到之前不跟随，免得先滚到半路。
    private var pendingUserId: String?
    /// 下一次跟随用动画（发出新消息、点回到底部）。
    private var animateNextFollow = false
    /// 上一次完整布局，用于识别真正的向前分页并选取仍存在的阅读锚点。
    private var geometry: ConversationGeometry?
    /// 页内 Markdown 等可能分多轮才量到最终高度；持续守同一存活行，直到下一次用户意图。
    private var prependAnchor: (id: String, y: CGFloat)?
    private var animatingTo: CGFloat?
    /// 平滑滚动自己逐帧推进，不交给 NSClipView 的 animator：那样 AppKit 会在帧之间自己改偏移，和这里的放回互相拉扯。
    /// 用定时器而不是 display link：窗口被遮住或隐藏时 display link 停摆，动画收不了尾，跟随就一直卡着。
    private var animation: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval)?
    private var timer: Timer?
    private var userScrolling = false
    /// apply 进行中：改文档高度时 AppKit 会顺手调一下偏移并发通知，这些回声不再触发 apply。
    private var applying = false

    func presentInitialLayout() {
        guard let lastUserY, let scrollView else { return }
        following = false
        setOffset(max(0, lastUserY - Self.anchorMargin))
        following = scrollView.contentView.bounds.maxY >= baseHeight(viewport: scrollView.contentView.bounds.height) - 2
        apply()
    }

    func attach(scrollView: ConversationScrollView, document: NSView) {
        detach()
        self.scrollView = scrollView
        self.document = document
        scrollView.scroller = self
        let clip = scrollView.contentView
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.boundsChanged() }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            },
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrollBegan() }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrollEnded() }
            },
        ]
        apply()
    }

    isolated deinit {
        timer?.invalidate()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func detach() {
        cancelAnimation()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        scrollView?.scroller = nil
        scrollView = nil
        document = nil
        onMetrics = nil
    }

    // MARK: 来自 SwiftUI 内容的测量

    func layoutChanged(_ value: ConversationGeometry) {
        PerfTrace.count("geometry_layout")
        let previous = geometry
        geometry = value
        #if DEBUG
        if contentEnd != value.end { trace("content \(contentEnd) -> \(value.end)") }
        #endif
        contentEnd = value.end
        lastUserId = value.lastUserId
        lastUserY = value.lastUserId.flatMap { value.rows[$0] }
        if let pendingUserId, pendingUserId == lastUserId, lastUserY != nil {
            self.pendingUserId = nil
            animateNextFollow = true
        }
        var shift: CGFloat = 0
        if let previous, let oldSeq = previous.firstSeq, let newSeq = value.firstSeq, newSeq < oldSeq {
            // 首条 id 替换不等于分页；只有日志 seq 真正向前，并且锚点仍存在才补偿。
            // 选离视口顶部最近的存活行，尾部同时增高不会混进这行的坐标差。
            let offset = scrollView?.contentView.bounds.minY ?? 0
            if let anchor = previous.rows.filter({ value.rows[$0.key] != nil })
                .min(by: { abs($0.value - offset) < abs($1.value - offset) }) {
                prependAnchor = (anchor.key, anchor.value)
            }
        }
        if let anchor = prependAnchor, let y = value.rows[anchor.id] {
            shift = y - anchor.y
            prependAnchor = (anchor.id, y)
            #if DEBUG
            if shift != 0 { trace("prepend anchor \(anchor.id) y \(anchor.y) -> \(y) shift \(shift)") }
            #endif
        } else {
            prependAnchor = nil
        }
        apply(shiftBy: shift)
    }

    // MARK: 意图

    /// 用户点开或收起：从此原地不动，直到用户滚回底部或发出新消息。
    func hold() {
        prependAnchor = nil
        following = false
        cancelAnimation()
    }

    /// 自己发出新消息：量到这条消息的位置后平滑顶到上方，之后回复长过一屏再跟随。
    func sent(_ id: String) {
        prependAnchor = nil
        following = true
        cancelAnimation()
        if lastUserId == id {
            pendingUserId = nil
            // 位置已经先量到了（两边更新先后不定）
            animateNextFollow = true
            apply()
        } else {
            pendingUserId = id
        }
    }

    /// 回到底部按钮。
    func scrollToEnd() {
        prependAnchor = nil
        pendingUserId = nil
        following = true
        animateNextFollow = true
        apply()
    }

    /// 自动化 `scroll:<y>`：模拟用户翻到某处。
    func userScroll(to y: CGFloat) {
        prependAnchor = nil
        following = false
        cancelAnimation()
        setOffset(y)
        apply()
    }

    func userScrollBegan() {
        prependAnchor = nil
        userScrolling = true
        following = false
        cancelAnimation()
    }

    func userScrollEnded() {
        userScrolling = false
        guard let scrollView else { return }
        let clip = scrollView.contentView
        // 停在真实内容的底部（含本轮留白）或更下面就恢复跟随
        following = clip.bounds.minY + clip.bounds.height >= baseHeight(viewport: clip.bounds.height) - 2
        apply()
    }

    // MARK: 布局

    private func turnSpace(viewport: CGFloat) -> CGFloat {
        guard let lastUserY, viewport > 0 else { return 0 }
        return max(0, viewport - Self.anchorMargin - (contentEnd + Self.bottomPadding - lastUserY))
    }

    /// 内容 + 底部边距 + 本轮留白；不含为保持偏移而留的那截。
    private func baseHeight(viewport: CGFloat) -> CGFloat {
        contentEnd + Self.bottomPadding + turnSpace(viewport: viewport)
    }

    private func boundsChanged() {
        guard !applying else { return }
        #if DEBUG
        if let offset = scrollView?.contentView.bounds.minY { trace("offset -> \(offset)") }
        #endif
        apply()
    }

    /// 唯一改文档高度和偏移的地方。先定高度再动偏移，偏移永远落在合法范围内，不会被夹回。
    private func apply(shiftBy shift: CGFloat = 0) {
        guard !applying, let scrollView, let document else { return }
        applying = true
        defer { applying = false }
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        let width = clip.bounds.width
        guard viewport > 0 else { return }
        let base = baseHeight(viewport: viewport)
        var offset = clip.bounds.minY
        // 先限制旧坐标的回弹，再加分页位移；新插入的高度尚未写入文档，不能用旧范围夹掉补偿。
        if userScrolling { offset = min(max(0, offset), max(0, document.frame.height - viewport)) }
        offset = max(0, offset + shift)
        if shift != 0, var animation {
            // 分页若撞上有意导航，动画的起终点也平移，下一帧不能退回旧绝对坐标。
            animation.from += shift
            animation.to += shift
            self.animation = animation
            animatingTo = animation.to
        }
        var target = offset
        if following, pendingUserId == nil, animatingTo == nil {
            // 跟随只往下走：底部留白还没用完时停在原处
            target = max(offset, base - viewport)
        }
        // 文档至少留到当前偏移、目标和进行中动画的终点各自加一个视口；往上翻后多出来的部分在视口下面，收掉看不见
        let keep = max(offset, target, animatingTo ?? 0)
        let height = max(base, keep + viewport)
        if document.frame.size != NSSize(width: width, height: height) {
            document.setFrameSize(NSSize(width: width, height: height))
        }
        if animateNextFollow, shift == 0, target != offset, !userScrolling {
            setOffset(offset)
            animate(to: target)
        } else if animatingTo == nil || shift != 0, clip.bounds.minY != target {
            // 改高度时 AppKit 可能顺手挪了偏移，这里明确放回目标，同一轮里完成，画面看不到中间值
            setOffset(target)
        }
        // 这一轮没等到要量的消息，就不再留着“下次用动画”
        if pendingUserId == nil { animateNextFollow = false }
        #if DEBUG
        if clip.bounds.minY != offset - shift { trace("offset -> \(clip.bounds.minY)") }
        #endif
        #if DEBUG
        trace("metrics offset \(clip.bounds.minY) viewport \(viewport) end \(contentEnd) userY \(lastUserY ?? -1) following \(following)")
        #endif
        onMetrics?(Metrics(offset: clip.bounds.minY, viewport: viewport, distanceToEnd: contentEnd - (clip.bounds.minY + viewport)))
    }

    private func setOffset(_ y: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, (document?.frame.height ?? 0) - clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    private func animate(to y: CGFloat) {
        guard let scrollView else { return }
        animatingTo = y
        animateNextFollow = false
        let duration: CFTimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.35
        animation = (scrollView.contentView.bounds.minY, y, CACurrentMediaTime(), duration)
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        step()
    }

    private func step() {
        guard let animation else { return }
        let t = animation.duration > 0 ? min(1, (CACurrentMediaTime() - animation.start) / animation.duration) : 1
        // 先快后慢地停下（接近 cubic-bezier(0.2, 0.8, 0.2, 1)）
        let eased = 1 - pow(1 - t, 4)
        let wasApplying = applying
        applying = true
        setOffset(animation.from + (animation.to - animation.from) * eased)
        applying = wasApplying
        #if DEBUG
        if let offset = scrollView?.contentView.bounds.minY { trace("offset -> \(offset)") }
        #endif
        if t >= 1 {
            stopAnimation()
            apply()
        }
    }

    private func stopAnimation() {
        animation = nil
        animatingTo = nil
        timer?.invalidate()
        timer = nil
    }

    /// 停在当前画面的位置，不跳到终点。
    private func cancelAnimation() {
        animateNextFollow = false
        stopAnimation()
    }
}
