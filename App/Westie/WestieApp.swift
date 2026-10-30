import AppKit
import SwiftUI

@main
struct WestieApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Westie", id: "main") {
            RootView(model: appDelegate.model, layout: appDelegate.layout)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    appDelegate.model.appearance.apply()
                    await appDelegate.model.start()
                    #if DEBUG
                    await Automation.runIfRequested(model: appDelegate.model, layout: appDelegate.layout)
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .commands { PanelCommands(model: appDelegate.model, layout: appDelegate.layout) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let configuration: KernelConfiguration = {
        do {
            return try .development()
        } catch {
            fatalError("无法定位开发期内核：\(error)")
        }
    }()

    @MainActor let model = AppModel(configuration: AppDelegate.configuration)

    /// 自动化测试的布局存在单独的配置文件里（见 `ConfigStore.shared`），不动日常使用的面板布局。
    @MainActor let layout = PanelLayout(dataScope: AppDelegate.configuration.dataScope)

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

/// 菜单栏：「新会话…」（⌘N）弹出选工作区的面板；「设置…」（⌘,）打开设置卡片；「面板」显示或收起各面板，找回会话列表。
private struct PanelCommands: Commands {
    let model: AppModel
    let layout: PanelLayout

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新会话…") { model.showingNewSession = true }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { layout.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("面板") {
            Button("主边栏") { layout.toggle(.primary) }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!layout.canToggle(.primary))
            Button("侧边栏") { layout.toggle(.secondary) }
                .keyboardShortcut("s", modifiers: [.control, .option, .command])
                .disabled(!layout.canToggle(.secondary))
            Button("顶部面板") { layout.toggle(.top) }
                .disabled(!layout.canToggle(.top))
            Button("底部面板") { layout.toggle(.bottom) }
                .keyboardShortcut("j", modifiers: .command)
                .disabled(!layout.canToggle(.bottom))
            Divider()
            Button("显示会话列表") { layout.showSessions() }
        }
    }
}
