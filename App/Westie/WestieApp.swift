import AppKit
import SwiftUI

@main
struct WestieApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Westie", id: "main") {
            KernelStatusView(host: appDelegate.host)
                .task { await appDelegate.host.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let host = KernelHost()

    /// 等内核排空持久化后再退出（KernelProcess.stop 最多等 5 秒）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await host.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// 第 1 步的占位界面：只显示内核状态。正式界面按主窗口 v7 在后续步骤实现。
struct KernelStatusView: View {
    let host: KernelHost

    var body: some View {
        Group {
            switch host.state {
            case .starting:
                ProgressView("正在启动内核…")
            case .connected(let sessions):
                Label("内核已连接 · \(sessions) 个会话", systemImage: "checkmark.circle")
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
    }
}
