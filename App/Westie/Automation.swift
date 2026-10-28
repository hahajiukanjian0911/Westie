#if DEBUG
import AppKit
import Foundation
import WestieKit

/// 开发期自动化：按 `WESTIE_AUTOMATION` 里分号分隔的步骤驱动 App，用于后台验证。
/// 只调用 App 自己的模型方法、截自己窗口的内容，不合成任何鼠标键盘事件，也不前置窗口。
///
/// 步骤：`workspace:<路径>` `new` `prompt:<文本>` `wait:<秒>` `idle`（等回合结束）
///      `approve` `reject` `answer:<选项>` `shot:<png 路径>` `quit`
@MainActor
enum Automation {
    static func runIfRequested(model: AppModel) async {
        guard let script = ProcessInfo.processInfo.environment["WESTIE_AUTOMATION"] else { return }
        let log = ProcessInfo.processInfo.environment["WESTIE_AUTOMATION_LOG"].map { URL(filePath: $0) }
        func note(_ line: String) {
            guard let log else { return }
            let data = Data("\(Date().formatted(.iso8601)) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: log) {
                _ = try? handle.seekToEnd()
                handle.write(data)
            } else {
                try? data.write(to: log)
            }
        }
        guard model.phase == .ready else { note("FAIL 内核未就绪：\(model.phase)"); return }
        note("ready")

        for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            let (verb, argument) = step.firstIndex(of: ":").map {
                (String(step[..<$0]), String(step[step.index(after: $0)...]))
            } ?? (step, "")
            switch verb {
            case "workspace":
                if !model.board.ordered.contains(where: { $0.path == argument }) {
                    await model.addWorkspace(path: argument)
                    await until { model.board.ordered.contains { $0.path == argument } }
                }
            case "new":
                guard let workspace = model.board.ordered.first else { note("FAIL 没有工作区"); continue }
                await model.newSession(in: workspace)
                await until { model.conversation?.isLoading == false }
            case "prompt":
                guard let id = model.selectedSessionId else { note("FAIL 没有选中会话"); continue }
                await model.send(argument, to: id)
                await until { model.conversation?.transcript.running == true }
            case "idle":
                await until(timeout: 20) {
                    model.conversation?.transcript.running == false
                        || !model.approvals.isEmpty || !model.questions.isEmpty
                }
            case "wait":
                try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
            case "approve", "reject":
                await until { !model.approvals.isEmpty }
                if let approval = model.approvals.first { await model.answer(approval, allow: verb == "approve") }
            case "answer":
                await until { !model.questions.isEmpty }
                if let question = model.questions.first, let item = question.items.first {
                    await model.answer(question, selections: [item.id: [argument]], custom: [:])
                }
            case "shot":
                try? await Task.sleep(for: .milliseconds(400))
                note(snapshot(to: URL(filePath: argument)) ? "shot \(argument)" : "FAIL shot \(argument)")
            case "dump":
                // 侧栏的毛玻璃材质 cacheDisplay 画不出来，用数据核对侧栏内容。
                for workspace in model.board.ordered {
                    let rows = model.sessions(in: workspace).map {
                        "\($0.displayTitle)\($0.running ? "[运行中]" : "")\($0.id == model.selectedSessionId ? "[选中]" : "")"
                    }
                    note("sidebar \(workspace.title): \(rows.joined(separator: " | "))")
                }
            case "quit":
                note("quit")
                RunLoop.main.perform { NSApp.terminate(nil) }
                return
            default:
                note("FAIL 未知步骤 \(step)")
            }
            note("done \(step) | items=\(model.conversation?.transcript.items.count ?? -1) running=\(model.conversation?.transcript.running ?? false) approvals=\(model.approvals.count) questions=\(model.questions.count)")
        }
    }

    private static func until(timeout: Double = 10, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 把主窗口内容渲染成 PNG（cacheDisplay 不需要屏幕录制权限，也不激活窗口）。
    private static func snapshot(to url: URL) -> Bool {
        guard let view = NSApp.windows.first(where: { $0.contentView != nil && $0.title == "Westie" })?.contentView
            ?? NSApp.windows.first?.contentView,
            let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return false }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? png.write(to: url)) != nil
    }
}
#endif
