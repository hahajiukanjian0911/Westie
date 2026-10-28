import AppKit
import SwiftUI

@main
struct WestieApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Westie", id: "main") {
            RootView(model: appDelegate.model)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    await appDelegate.model.start()
                    #if DEBUG
                    await Automation.runIfRequested(model: appDelegate.model)
                    #endif
                }
        }
        .defaultSize(width: 1100, height: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model: AppModel = {
        do {
            return AppModel(configuration: try .development())
        } catch {
            fatalError("无法定位开发期内核：\(error)")
        }
    }()

    /// 等内核排空持久化后再退出（KernelProcess.stop 最多等 5 秒）。
    /// 收尾不走主 actor，答复也不走主队列：AppKit 在嵌套事件循环里等答复，若 terminate 正是从
    /// 主 actor 任务或主队列 block 里调用的，排在它们上面的工作都轮不到。所以在后台结束连接与内核，
    /// 再用 RunLoop 投递答复（嵌套循环也会执行 common 模式的 RunLoop block）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let handles = MainActor.assumeIsolated { model.prepareShutdown() }
        Task.detached {
            await handles.connection?.disconnect()
            await handles.kernel?.stop()
            RunLoop.main.perform(inModes: [.common]) { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
