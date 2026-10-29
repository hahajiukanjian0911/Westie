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
        expect(offset() == 1024 - viewport, "首次打开贴底")
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
        print("\(checks) checks passed")
    }
    static func runLoop(for duration: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
}
