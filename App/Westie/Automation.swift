#if DEBUG
import AppKit
import Foundation
import SwiftUI
import WestieKit

/// 开发期自动化：按 `WESTIE_AUTOMATION` 里分号分隔的步骤驱动 App，用于后台验证。
/// 只调用 App 自己的模型方法、截自己窗口的内容，不合成任何鼠标键盘事件，也不前置窗口。
///
/// 步骤：`workspace:<路径>` `new` `prompt:<文本>` `wait:<秒>` `idle`（等回合结束）
///      `approve` `reject` `answer:<选项>` `select:<序号或会话 id>` `earlier[:<页数>]`（往前翻页） `shot:<png 路径>` `dump` `quit`
///      面板：`split:<序号>`（并排打开第 n 个会话） `move:<面板>`（聚焦窗口移到 top/primary/center/secondary/bottom）
///      `toggle:<面板>` `hide` `appearance:dark|light`（收起聚焦窗口） `layout`（记录各面板的窗口）
///      拖放：`drag:<x>,<y>`（从聚焦窗口标题栏拖到 Workbench 坐标）`drag:<面板>.<n>@<fx>,<fy>`（拖到某面板第 n 个窗口内的比例位置）
///      `drag:edge.<primary|secondary|bottom>` `drag:map.<面板>`（经上沿布局条） `drop` `cancel` `hover:<面板>`（布局按钮悬停预览）
///      `grips` / `grips:off`（所有窗口的顶部拖动条常亮，用于截图）
///      设置：`settings[:<分页>]`（打开设置卡片并记录读到的值） `theme:<序号>`（换主题） `set:<键>=<值>`（写内核设置后重读）
///
/// 只有假模型模式（`WESTIE_MOCK_LLM`）允许会写数据或发消息的步骤；连真实 `~/.dsh` 时只能
/// 选会话、截图、核对，任何会建会话、发消息、答复审批的步骤都拒绝执行。
@MainActor
enum Automation {
    static func runIfRequested(model: AppModel, layout: PanelLayout) async {
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
        guard model.phase == .ready else {
            note("FAIL 内核未就绪：\(model.phase)")
            if script.hasSuffix("quit") { RunLoop.main.perform { NSApp.terminate(nil) } }
            return
        }
        note("ready mock=\(model.isMock)")
        let writingSteps: Set<String> = ["workspace", "new", "prompt", "approve", "reject", "answer", "set"]

        for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
            let (verb, argument) = step.firstIndex(of: ":").map {
                (String(step[..<$0]), String(step[step.index(after: $0)...]))
            } ?? (step, "")
            if !model.isMock, writingSteps.contains(verb) {
                note("REFUSED \(step)：连的是真实数据，只允许只读步骤")
                continue
            }
            switch verb {
            case "split":
                await until { !model.board.ordered.isEmpty }
                let all = model.board.ordered.flatMap { model.sessions(in: $0) }
                guard let index = Int(argument), all.indices.contains(index) else { note("FAIL 没有第 \(argument) 个会话"); continue }
                layout.openConversation(all[index].id, mode: .sideBySide)
                await until { model.conversations[all[index].id]?.isLoading == false }
            case "move", "toggle":
                guard let panel = PanelID(rawValue: argument) else { note("FAIL 没有面板 \(argument)"); continue }
                if verb == "toggle" {
                    layout.toggle(panel)
                } else if let id = layout.focusedWindowId {
                    layout.move(id, to: panel)
                }
            case "appearance":
                // 只改 App 自己的外观，不动系统深浅色。
                NSApp.appearance = NSAppearance(named: argument == "dark" ? .darkAqua : .aqua)
                try? await Task.sleep(for: .milliseconds(300))
            case "drag":
                guard let id = layout.drag?.windowId ?? layout.focusedWindowId, let tile = layout.tileFrames[id] else {
                    note("FAIL 没有可拖的窗口"); continue
                }
                let start = CGPoint(x: tile.midX, y: tile.minY + 18)
                if layout.drag == nil { layout.updateDrag(id, at: CGPoint(x: start.x, y: start.y + 8), from: start) }
                guard let points = dragPoints(argument, layout: layout) else { note("FAIL 看不懂拖放位置 \(argument)"); continue }
                for point in points {
                    layout.updateDrag(id, at: point, from: start)
                    try? await Task.sleep(for: .milliseconds(250))
                }
                note("drag target=\(layout.drag?.target.map { "\($0.panel.rawValue) \($0.kind) @\($0.index)" } ?? "无") map=\(layout.drag?.mapOpen ?? false)")
            case "drop":
                withAnimation(Workbench.settle) { layout.endDrag() }
                try? await Task.sleep(for: .milliseconds(500))
                note("assisting=\(layout.assisting.map(\.rawValue).sorted())")
            case "cancel":
                layout.cancelDrag()
            case "grips":
                layout.gripsShown = argument != "off"
            case "hover":
                guard let panel = PanelID(rawValue: argument), let id = layout.focusedWindowId else { note("FAIL hover \(argument)"); continue }
                layout.hoverTarget = layout.appendTarget(panel, dragging: id)
            case "hide":
                if let id = layout.focusedWindowId { layout.hide(id) }
            case "layout":
                for panel in PanelID.allCases {
                    let shown = layout.shownWindows(in: panel).map {
                        "\($0.content.title(model: model))\($0.id == layout.focusedWindowId ? "[聚焦]" : "")"
                    }
                    let hidden = layout.hiddenWindows(in: panel).map { $0.content.title(model: model) }
                    note("panel \(panel.rawValue) visible=\(layout.isVisible(panel)) shown=[\(shown.joined(separator: ", "))] hidden=[\(hidden.joined(separator: ", "))]")
                }
            case "select":
                await until { !model.board.ordered.isEmpty }
                let all = model.board.ordered.flatMap { model.sessions(in: $0) }
                // 序号或会话 id
                guard let id = Int(argument).flatMap({ all.indices.contains($0) ? all[$0].id : nil })
                    ?? all.first(where: { $0.id == argument })?.id else { note("FAIL 没有会话 \(argument)"); continue }
                model.selectedSessionId = id
                await until { model.conversation?.isLoading == false }
            case "earlier":
                // 往前翻页 n 次（默认翻到底），只读。
                guard let conversation = model.conversation else { note("FAIL 没有打开的会话"); continue }
                var pages = 0
                // 只数真正接上了记录的页；没有进展（出错或已到头）就停，不空转
                while conversation.hasEarlierHistory, pages < (Int(argument) ?? .max) {
                    guard await conversation.loadEarlier() else {
                        if let error = conversation.earlierError { note("FAIL earlier \(error)") }
                        break
                    }
                    pages += 1
                }
                note("earlier pages=\(pages) firstSeq=\(conversation.transcript.firstSeq ?? -1) hasMore=\(conversation.hasEarlierHistory)")
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
                let before = model.conversation?.transcript.items.count ?? 0
                await model.send(argument, to: id)
                // 假模型很快，可能还没看到“运行中”就已经回完了。
                await until {
                    model.conversation?.transcript.running == true || (model.conversation?.transcript.items.count ?? 0) > before
                }
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
            case "settings":
                // 打开设置卡片，可带分页：general / account / appearance / advanced
                if let tab = SettingsTab(rawValue: argument) { model.settings.tab = tab }
                layout.showSettings()
                await until { model.settings.loaded }
                note("settings tab=\(model.settings.tab.rawValue) model=\(model.settings.defaultModel.map { "\($0.model)/\($0.effort ?? "-")" } ?? "nil") preset=\(model.settings.permissionPreset) log=\(model.settings.sessionLog) depth=\(model.settings.maxDepth) active=\(model.settings.maxActive) key=\(model.settings.apiKeyConfigured) account=\(model.settings.account) theme=\(model.appearance.themeIndex) grain=\(model.appearance.grain) mode=\(model.appearance.mode.rawValue)")
            case "set":
                // 写内核设置：depth=<n> active=<n> preset=<名> log=<true|false> effort=<档位>
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { note("FAIL set 需要 键=值"); continue }
                let settings = model.settings
                switch parts[0] {
                case "depth": await settings.setMaxDepth(Int(parts[1]) ?? settings.maxDepth)
                case "active": await settings.setMaxActive(Int(parts[1]) ?? settings.maxActive)
                case "preset": await settings.setPermission(parts[1])
                case "log": await settings.setSessionLog(parts[1] == "true")
                case "effort":
                    if let current = settings.defaultModel, let choice = model.models.first(where: { $0.provider == current.provider && $0.model == current.model }) {
                        await settings.setDefaultModel(choice, effort: parts[1])
                    }
                default: note("FAIL 未知设置 \(parts[0])")
                }
                await settings.load()
                note("after set: model=\(settings.defaultModel.map { "\($0.model)/\($0.effort ?? "-")" } ?? "nil") preset=\(settings.permissionPreset) log=\(settings.sessionLog) depth=\(settings.maxDepth) active=\(settings.maxActive) error=\(settings.error ?? "-")")
            case "theme":
                if let index = Int(argument) { model.appearance.themeIndex = index }
                try? await Task.sleep(for: .milliseconds(300))
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

    /// 拖放步骤的指针轨迹（Workbench 坐标）。
    private static func dragPoints(_ argument: String, layout: PanelLayout) -> [CGPoint]? {
        let bounds = layout.bounds
        let center = layout.panelFrames[.center] ?? bounds
        if argument.hasPrefix("edge.") {
            switch argument.dropFirst(5) {
            case "primary": return [CGPoint(x: bounds.minX + 6, y: bounds.midY)]
            case "secondary": return [CGPoint(x: bounds.maxX - 6, y: bounds.midY)]
            case "bottom": return [CGPoint(x: center.midX, y: bounds.maxY - 6)]
            default: return nil
            }
        }
        if argument.hasPrefix("map.") {
            guard let panel = PanelID(rawValue: String(argument.dropFirst(4))),
                  let cell = PanelLayout.mapCells(in: layout.mapFrame)[panel] else { return nil }
            return [CGPoint(x: center.midX, y: bounds.minY + 6), CGPoint(x: cell.midX, y: cell.midY)]
        }
        if let at = argument.firstIndex(of: "@") {
            let parts = argument[..<at].split(separator: ".")
            let fractions = argument[argument.index(after: at)...].split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, let panel = PanelID(rawValue: String(parts[0])), let index = Int(parts[1]), fractions.count == 2 else { return nil }
            let shown = layout.shownWindows(in: panel)
            guard shown.indices.contains(index), let tile = layout.tileFrames[shown[index].id] else { return nil }
            return [CGPoint(x: tile.minX + tile.width * fractions[0], y: tile.minY + tile.height * fractions[1])]
        }
        let numbers = argument.split(separator: ",").compactMap { Double($0) }
        return numbers.count == 2 ? [CGPoint(x: numbers[0], y: numbers[1])] : nil
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
