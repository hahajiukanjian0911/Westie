import AppKit
import SwiftUI

/// 红绿灯放到顶栏中线，和侧栏开关、卡片标题对齐（设计稿 2026-10-28-panels v4）。
/// 给窗口挂一条空的统一样式工具栏：系统把标题栏撑到 52pt（= `Metrics.lightsHeight`），红绿灯在其中居中。
/// 手动挪按钮会在 AppKit 每次重排标题栏时被复原，所以不走那条路。
struct TrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {}

    final class Host: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "westie.titlebar")
            toolbar.showsBaselineSeparator = false
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
