import AppKit
import SwiftUI

/// 离屏 AppKit 回归：不创建窗口、不合成输入，直接驱动唯一滚动协调者。
@main @MainActor struct ConversationScrollerChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
        print("PASS \(message)")
    }
    static func main() {
        let view = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.hasVerticalScroller = false
        view.contentView.postsBoundsChangedNotifications = true
        view.contentView.postsFrameChangedNotifications = true
        let document = FlippedView()
        view.documentView = document
        let scroller = ConversationScroller()
        scroller.attach(scrollView: view, document: document)
        expect(!scroller.hasMeasuredHistory, "空宿主偏移0不触发历史分页")
        let viewport = view.contentView.bounds.height
        func layout(_ end: CGFloat, _ seq: Int = 100, _ rows: [String: CGFloat] = ["user": 100], user: String? = "user") {
            scroller.layoutChanged(.init(end: end, firstSeq: seq, lastUserId: user, rows: rows))
        }
        func offset() -> CGFloat { view.contentView.bounds.minY }
        layout(1000)
        expect(scroller.hasMeasuredHistory, "快照已布局才允许按顶部位置翻页")
        scroller.presentInitialLayout()
        expect(offset() == 100 - 16, "首次打开实际末轮用户行贴顶16pt")
        scroller.userScroll(to: 150)
        layout(1300, 50, ["older": 8, "user": 300]) // 前面+200，尾部+100
        expect(offset() == 350, "分页同时尾部增高，仅补偿锚点200pt")
        layout(1400, 50, ["replacement": 8, "user": 300])
        expect(offset() == 350, "首行替换和尾部增长不误判分页")
        layout(1400, 25, ["older2": 8, "user": 400]) // 总高不变：前面+100，尾部-100
        expect(offset() == 450, "分页总高不变仍补偿锚点100pt")
        layout(1500, 25, ["older2": 8, "user": 400])
        expect(offset() == 450, "分页后尾部再增长不重复补偿")
        layout(1600, 25, ["older2": 8, "user": 500])
        expect(offset() == 550, "分页内容延后换行，继续补偿同一锚点100pt")
        scroller.hold()
        layout(1700, 25, ["older2": 8, "user": 600])
        expect(offset() == 550, "下一次展开意图清除分页锚点，不再追随旧行")
        scroller.userScrollBegan()
        layout(2700, 10, ["older3": 8, "user": 1600])
        expect(offset() == 1550, "手势中分页补偿不被旧文档范围夹断")
        scroller.userScrollEnded()
        scroller.userScroll(to: 450)
        layout(200, 10, ["older3": 8, "user": 100])
        expect(offset() == 450, "内容缩短保持offset并保留合法文档范围")
        expect(document.frame.height >= offset() + viewport, "文档保留足够高度")
        scroller.userScroll(to: 0)
        layout(1000, 25, ["user": 100])
        scroller.userScrollBegan()
        layout(1200, 25, ["user": 100])
        expect(offset() == 0 && !scroller.following, "用户滚动期间内容增高不跟随")
        scroller.userScrollEnded()
        expect(!scroller.following, "离底部松手仍暂停")
        scroller.userScroll(to: 2000)
        scroller.userScrollEnded()
        expect(scroller.following, "滚到真实底部松手恢复跟随")
        let beforeGrowth = offset()
        layout(1400, 25, ["user": 100])
        expect(offset() > beforeGrowth, "恢复后长回复向下跟随")
        let beforeShrink = offset()
        layout(1200, 25, ["user": 100])
        expect(offset() == beforeShrink, "跟随不因内容缩短倒退")
        scroller.hold()
        layout(1600, 25, ["user": 100])
        expect(offset() == beforeShrink && !scroller.following, "展开暂停后新内容不挪动偏移")

        scroller.sent("next")
        let pendingOffset = offset()
        layout(1700, 25, ["user": 100])
        expect(offset() == pendingOffset, "发送未量到新用户行前不跟随")
        layout(1800, 25, ["user": 100, "next": 1700], user: "next")
        runLoop(for: 0.45)
        expect(abs(offset() - (1700 - 16)) < 0.01, "先发送再测量：用户行顶到16pt")
        scroller.hold()
        layout(2000, 25, ["next": 1700, "third": 1900], user: "third")
        scroller.sent("third")
        runLoop(for: 0.45)
        expect(abs(offset() - (1900 - 16)) < 0.01, "先测量再发送：用户行顶到16pt")
        scroller.userScroll(to: 0)
        scroller.scrollToEnd()
        let beforePrepend = offset()
        layout(2500, 1, ["older": 8, "next": 2200, "third": 2400], user: "third")
        expect(abs(offset() - beforePrepend - 500) < 0.01, "动画中分页同轮补偿500pt")
        runLoop(for: 0.45)
        expect(abs(offset() - (2400 - 16)) < 0.01, "分页平移动画终点，后续帧不退回旧坐标")
        let beforeResize = offset()
        scroller.hold()
        view.setFrameSize(NSSize(width: 400, height: 600))
        view.tile()
        layout(2300, 25, ["third": 2100], user: "third")
        expect(offset() == beforeResize, "窗口变宽高并重新测量时保持偏移")

        scroller.scrollToEnd()
        let timer = Mirror(reflecting: scroller).children.first(where: { $0.label == "timer" })?.value as? Timer
        scroller.detach()
        expect(view.scroller == nil && timer?.isValid != true, "拆卸解除宿主并失效Timer")
        var ephemeral: ConversationScroller? = ConversationScroller()
        ephemeral?.attach(scrollView: view, document: document)
        ephemeral?.layoutChanged(.init(end: 4000, firstSeq: 1, lastUserId: nil, rows: [:]))
        ephemeral?.userScroll(to: 0)
        ephemeral?.scrollToEnd()
        let orphanTimer = Mirror(reflecting: ephemeral!).children.first(where: { $0.label == "timer" })?.value as? Timer
        expect(orphanTimer?.isValid == true, "析构回归前已启动Timer")
        weak let released = ephemeral
        ephemeral = nil
        expect(released == nil && orphanTimer?.isValid == false, "析构失效RunLoop持有的Timer")
        chunkChecks()
        viewportChecks()
        print("\(checks) checks passed")
    }
    @MainActor @Observable final class ChunkState {
        let id: String
        var height: CGFloat
        var ready = true
        init(_ id: String, _ height: CGFloat) { self.id = id; self.height = height }
    }
    struct ChunkContent: View, Equatable {
        let state: ChunkState
        nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.state === rhs.state }
        var body: some View {
            Color.clear.frame(height: state.height)
                .anchorPreference(key: ConversationChunkRows.self, value: .bounds) { [state.id: $0] }
                .preference(key: ConversationChunkReady.self, value: state.ready)
        }
    }
    static func chunkChecks() {
        let scroll = ConversationScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scroll.hasVerticalScroller = false
        let document = ConversationChunkDocument<ChunkContent>()
        scroll.documentView = document
        let scroller = ConversationScroller()
        document.scroller = scroller
        scroller.attach(scrollView: scroll, document: document)
        let a = ChunkState("a", 600), b = ChunkState("b", 300), old = ChunkState("old", 400)
        b.ready = false
        var readyCount = 0
        func update(_ values: [ChunkState], seq: Int) {
            document.update(values.map { .init(id: $0.id, content: ChunkContent(state: $0)) },
                            firstSeq: seq, lastUserId: "b", columnWidth: nil,
                            onReady: { readyCount += 1 })
            settle()
        }
        func settle() {
            for _ in 0..<5 {
                document.layoutSubtreeIfNeeded()
                runLoop(for: 0.03)
            }
        }
        update([a, b], seq: 100)
        expect(readyCount == 0 && !scroller.hasMeasuredHistory && scroll.contentView.bounds.minY == 0,
               "首开未完成的块不发布历史、不滚动、不开放显示")
        a.height = 700
        b.ready = true
        settle()
        expect(readyCount == 1 && abs(scroll.contentView.bounds.minY - 708) < 0.01,
               "全部块就绪后按完整高度一次提交首开锚点")
        a.height = 600
        scroller.hold()
        settle()
        scroller.userScroll(to: 608)
        expect(document.subviews.count == 2, "切块一次创建全部宿主")
        expect(abs(document.subviews[1].frame.minY - 624) < 0.01, "切块初次测量后紧接上轮与16pt间距")
        expect(abs(scroll.contentView.bounds.minY - 608) < 0.01, "切块初始用户锚点贴顶16pt")
        let aView = document.subviews[0], bView = document.subviews[1]
        scroller.hold()
        let held = scroll.contentView.bounds.minY
        b.height = 700
        settle()
        expect(abs(bView.frame.height - 700) < 0.01, "块内观察变化同步宿主高度")
        expect(scroll.contentView.bounds.minY == held && aView.frame.height == 600, "展开尾块保持点击行与上方缓存高度")
        b.height = 100
        settle()
        expect(bView.frame.height == 100 && scroll.contentView.bounds.minY == held, "收起尾块保持位置及合法留白")
        scroller.userScroll(to: 500)
        let before = scroll.contentView.bounds.minY
        update([old, a, b], seq: 50)
        expect(document.subviews.contains { $0 === aView } && document.subviews.contains { $0 === bView }, "顶部插入复用已有宿主")
        expect(abs(scroll.contentView.bounds.minY - before - 416) < 0.01, "切块分页只补偿新块高度及间距")
        expect(abs(bView.frame.minY - 1040) < 0.01, "分页下方块仅平移不重复测量")
        scroller.detach()
    }

    /// 真实 SwiftUI 父布局分配视口，覆盖 sizeThatFits 的有限/未指定提案及窗口伸缩。
    static func viewportChecks() {
        let scroller = ConversationScroller()
        let state = ChunkState("viewport", 1200)
        let shell = NSHostingView(rootView: VStack(spacing: 0) {
            ConversationScroll(scroller: scroller,
                chunks: [ConversationChunk(id: state.id, content: ChunkContent(state: state))],
                firstSeq: 1, lastUserId: state.id, columnWidth: nil, loaded: true, onReady: {})
            Color.clear.frame(height: 80)
        })
        shell.sizingOptions = []
        func findScroll(_ view: NSView) -> ConversationScrollView? {
            if let scroll = view as? ConversationScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        func resize(_ size: CGSize) -> ConversationScrollView? {
            shell.setFrameSize(size)
            for _ in 0..<5 { shell.layoutSubtreeIfNeeded(); runLoop(for: 0.03) }
            return findScroll(shell)
        }
        let first = resize(CGSize(width: 600, height: 500))
        expect(first?.frame.size == CGSize(width: 600, height: 420), "SwiftUI父布局分配视口而非文档自然高度")
        let larger = resize(CGSize(width: 900, height: 800))
        expect(larger === first && larger?.frame.size == CGSize(width: 900, height: 720), "视口随父布局增大且复用滚动宿主")
        let smaller = resize(CGSize(width: 400, height: 300))
        expect(smaller === first && smaller?.frame.size == CGSize(width: 400, height: 220), "视口随父布局缩小且保留输入区高度")
        scroller.detach()
    }

    static func runLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
}
