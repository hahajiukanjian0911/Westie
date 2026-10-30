import SwiftUI

/// 滚动区域的边缘：内容滚出去的那一侧渐隐，不让一行字被硬生生横切。
/// 渐隐高度跟着“边外还有多少内容”长出来：在最顶上时顶部不淡，翻下去 `fade` 点后淡满；底部同理。
@MainActor @Observable
final class EdgeFadeState {
    var top: CGFloat = 0
    var bottom: CGFloat = 0

    /// 只在取整后的值变了才写，滚动中途不反复触发重绘。
    func update(above: CGFloat, below: CGFloat, fade: CGFloat) {
        let top = min(max(above, 0), fade).rounded()
        let bottom = min(max(below, 0), fade).rounded()
        if top != self.top { self.top = top }
        if bottom != self.bottom { self.bottom = bottom }
    }
}

/// 遮罩本身：上下两段渐变夹一块实心。单独成视图，只有它读状态，滚动时不牵动外层。
struct EdgeFadeMask: View {
    let state: EdgeFadeState

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: state.top)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: state.bottom)
        }
    }
}

private struct ScrollEdgeFade: ViewModifier {
    let fade: CGFloat
    @State private var state = EdgeFadeState()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: EdgeInsets.self) { geometry in
                let above = geometry.contentOffset.y + geometry.contentInsets.top
                let below = geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.contentOffset.y - geometry.containerSize.height
                return EdgeInsets(top: min(max(above, 0), fade).rounded(), leading: 0,
                                  bottom: min(max(below, 0), fade).rounded(), trailing: 0)
            } action: { _, edges in
                state.update(above: edges.top, below: edges.bottom, fade: fade)
            }
            .mask { EdgeFadeMask(state: state) }
    }
}

extension View {
    /// 给 SwiftUI 的 ScrollView 加边缘渐隐。
    func scrollEdgeFade(_ fade: CGFloat = 24) -> some View {
        modifier(ScrollEdgeFade(fade: fade))
    }
}
