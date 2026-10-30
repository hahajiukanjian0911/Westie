import AppKit
import Foundation
import Observation
import WestieKit

/// 一条等待用户审批的工具操作（`approval/request` waterfall）。
struct PendingApproval: Identifiable, Equatable {
    var id: String { eventId }
    let eventId: String
    let sessionId: String
    let toolName: String
    let reason: String
}

/// 一组等待用户回答的提问（`user-questions/request` waterfall）。
struct PendingQuestion: Identifiable, Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let header: String?
        let question: String
        let options: [(label: String, description: String?)]
        let multiSelect: Bool

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id && lhs.question == rhs.question }
    }

    var id: String { eventId }
    let eventId: String
    let sessionId: String
    let items: [Item]
}

struct ModelChoice: Hashable, Identifiable {
    var id: String { "\(provider)/\(model)" }
    let provider: String
    let model: String
    let name: String
    /// 提供方的显示名（如 API Key 与账号各一组时用来区分同名模型）。
    var group = ""
    let efforts: [String]
    let defaultEffort: String?
}

/// App 的根状态：内核生命周期、工作区与会话列表、选中的会话、待处理的审批与提问。
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case starting
        /// DSH.app 正在使用 `~/.dsh`，等它退出再启动内核。
        case waitingForDSH
        case ready
        case reconnecting
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var board = WorkspaceBoard()
    private(set) var sessions: [String: SessionSummary] = [:]
    private(set) var approvals: [PendingApproval] = []
    private(set) var questions: [PendingQuestion] = []
    private(set) var models: [ModelChoice] = []
    private(set) var defaultModel: ModelChoice?
    /// 正在显示的会话（由面板布局告知），每个跟读一条 `session/follow`。
    private(set) var conversations: [String: ConversationModel] = [:]
    /// ⌘N 的新建会话面板是否打开。
    var showingNewSession = false
    /// 当前聚焦的会话：侧栏高亮、新建会话后跳转都通过它与面板布局同步。
    var selectedSessionId: String?
    /// 聚焦会话的对话（自动化脚本用）。
    var conversation: ConversationModel? { selectedSessionId.flatMap { conversations[$0] } }
    private var wantedConversations: Set<String> = []

    private var kernel: KernelProcess?
    private(set) var connection: KernelConnection?
    private var connectionTasks: [Task<Void, Never>] = []
    private var listRefresh: Task<Void, Never>?
    private let configuration: KernelConfiguration

    /// Westie 自己的外观（UserDefaults）与写进内核的设置。
    let appearance = AppearanceSettings()
    let settings = SettingsModel()

    init(configuration: KernelConfiguration) {
        self.configuration = configuration
        // 每个数据目录各记各的，mock 不会清掉真实配置的记录。
        touchedKey = "sessionList.touchedAt:" + configuration.location.dshHome.standardizedFileURL.path
        let stored = UserDefaults.standard.dictionary(forKey: touchedKey) as? [String: Double]
            ?? (configuration.sharesDSHHome ? UserDefaults.standard.dictionary(forKey: "sessionList.restoredAt") as? [String: Double] : nil)
            ?? [:]
        touchedAt = stored.mapValues { Date(timeIntervalSince1970: $0) }
        UserDefaults.standard.removeObject(forKey: "sessionList.restoredAt")
        settings.app = self
    }

    // MARK: - 生命周期

    static let dshBundleIdentifier = "com.deepseek.dsh"

    var isDSHRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.dshBundleIdentifier).isEmpty
    }

    var isMock: Bool { configuration.isMock }

    func start() async {
        if configuration.sharesDSHHome {
            watchDSHApp()
            // 两个内核同时写 ~/.dsh 会互相覆盖 workspace.json：DSH.app 在跑就不启动。
            guard !isDSHRunning else {
                phase = .waitingForDSH
                return
            }
        }
        phase = .starting
        do {
            let kernel = KernelProcess(location: configuration.location, options: configuration.options)
            self.kernel = kernel
            let endpoint = try await kernel.start()
            // 启动途中 DSH.app 起来了：已经让位，这个内核直接停掉。
            guard phase == .starting else {
                await kernel.stop()
                return
            }
            try await attach(endpoint: endpoint)
        } catch {
            if phase == .starting { phase = .failed(String(describing: error)) }
        }
    }

    /// DSH.app 退出 → 若在等待就启动内核；DSH.app 启动 → 立即停掉我们的内核，把 ~/.dsh 让给它。
    private func watchDSHApp() {
        guard dshObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        dshObservers = [
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard AppModel.isDSH(note) else { return }
                MainActor.assumeIsolated {
                    guard let self, self.phase == .waitingForDSH, !self.isDSHRunning else { return }
                    Task { await self.start() }
                }
            },
        ]
        for name in [NSWorkspace.willLaunchApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            dshObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard AppModel.isDSH(note) else { return }
                MainActor.assumeIsolated { self?.yieldToDSH() }
            })
        }
    }

    private var dshObservers: [NSObjectProtocol] = []

    private nonisolated static func isDSH(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            == "com.deepseek.dsh"
    }

    private func yieldToDSH() {
        guard phase != .waitingForDSH else { return }
        let handles = prepareShutdown()
        phase = .waitingForDSH
        conversations = [:]
        connection = nil
        kernel = nil
        Task.detached {
            await handles.connection?.disconnect()
            await handles.kernel?.stop()
        }
    }

    /// 退出前：停掉长连任务并交出连接与内核，由调用方在主 actor 之外结束它们。
    func prepareShutdown() -> (connection: KernelConnection?, kernel: KernelProcess?) {
        phase = .failed("正在退出")
        connectionTasks.forEach { $0.cancel() }
        connectionTasks = []
        conversations.values.forEach { $0.close() }
        return (connection, kernel)
    }

    /// 接入内核并启动三条长连：转发事件、工作区跟读、会话列表。
    private func attach(endpoint: KernelEndpoint) async throws {
        connectionTasks.forEach { $0.cancel() }
        let connection = KernelConnection(endpoint: endpoint)
        let events = try await connection.connect(interactions: .answer)
        self.connection = connection
        approvals = []
        questions = []

        connectionTasks = [
            Task { [weak self] in
                for await event in events { self?.handle(event) }
                await self?.connectionLost(endpoint: endpoint)
            },
            Task { [weak self] in
                do {
                    for try await frame in await connection.stream("workspace/follow") { self?.board.apply(frame) }
                } catch {}
            },
        ]
        try await refreshSessions()
        try await loadModels()
        phase = .ready
        Task { await settings.load() }
        conversations.values.forEach { $0.close() }
        conversations = [:]
        retainConversations(wantedConversations)
    }

    /// 连接断开：内核还活着就重新接入，否则重启内核。最多重试 5 次，间隔递增。
    private func connectionLost(endpoint: KernelEndpoint) async {
        guard phase == .ready else { return }
        if configuration.sharesDSHHome, isDSHRunning {
            yieldToDSH()
            return
        }
        phase = .reconnecting
        for attempt in 1...5 {
            try? await Task.sleep(for: .milliseconds(300 * attempt))
            do {
                if let kernel, await kernel.isRunning {
                    try await attach(endpoint: endpoint)
                } else {
                    if configuration.sharesDSHHome, isDSHRunning { yieldToDSH(); return }
                    let kernel = KernelProcess(location: configuration.location, options: configuration.options)
                    self.kernel = kernel
                    try await attach(endpoint: kernel.start())
                }
                return
            } catch {
                continue
            }
        }
        phase = .failed("与内核的连接已断开，重连失败")
    }

    // MARK: - 会话列表

    private func refreshSessions() async throws {
        guard let connection else { return }
        let value = try await connection.call("session/list", ["_request": [:]])
        var next: [String: SessionSummary] = [:]
        for item in value["items"]?.arrayValue ?? [] {
            if let summary = SessionSummary(item) { next[summary.id] = summary }
        }
        // 列表里的标题来自缓存投影，改名后一段时间里新旧标题会交替出现：本次运行里改过的以本地为准。
        for (id, title) in renamedTitles { next[id]?.title = title }
        sessions = next
        // 已删除的会话、内核时间已经更新过的记录不用再记。
        let kept = touchedAt.filter { id, date in next[id].map { $0.updatedAt < date } ?? false }
        if kept.count != touchedAt.count {
            touchedAt = kept
            saveTouched()
        }
    }

    /// 会话状态变化后合并刷新一次列表（标题等投影在回合结束后更新）。
    private func scheduleSessionRefresh() {
        listRefresh?.cancel()
        listRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await self?.refreshSessions()
        }
    }

    /// 侧栏主列表：置顶的在前（按内核的置顶顺序），其余按最近活动排序。
    /// 排除已归档的、子 Agent 会话（收在父会话下）和没发过消息的空会话；分叉出的会话是独立会话，照常排进来。
    /// 空会话只在正选中时显示，发出第一条消息后就是正常会话。
    var activeSessions: [SessionSummary] { pinnedSessions + timelineSessions }

    var pinnedSessions: [SessionSummary] {
        board.pinnedSessionIds.compactMap { sessions[$0] }.filter { isListed($0) && !board.archivedSessionIds.contains($0.id) }
    }

    var timelineSessions: [SessionSummary] {
        let pinned = Set(board.pinnedSessionIds)
        return sessions.values
            .filter { isListed($0) && !pinned.contains($0.id) && !board.archivedSessionIds.contains($0.id) }
            .sorted { lastActive($0) > lastActive($1) }
    }

    /// 侧栏底部「归档」里的会话，按最近活动排序。
    var archivedSessions: [SessionSummary] {
        sessions.values
            .filter { !$0.isSubagent && board.archivedSessionIds.contains($0.id) }
            .sorted { lastActive($0) > lastActive($1) }
    }

    private func isListed(_ session: SessionSummary) -> Bool {
        !session.isSubagent && (!session.blank || session.id == selectedSessionId)
    }

    func isPinned(_ sessionId: String) -> Bool { board.pinnedSessionIds.contains(sessionId) }

    /// 某个会话派出的全部子 Agent 会话（含子 Agent 再派出的），按最近活动排序。
    func children(of sessionId: String) -> [SessionSummary] {
        var found: [SessionSummary] = []
        var queue = [sessionId]
        var seen: Set<String> = [sessionId]
        while let parent = queue.popLast() {
            for child in sessions.values where child.isSubagent && child.parentSessionId == parent && seen.insert(child.id).inserted {
                found.append(child)
                queue.append(child.id)
            }
        }
        return found.sorted { lastActive($0) > lastActive($1) }
    }

    /// 子 Agent 会话最上层的那个普通会话（侧栏里它挂在谁下面）。
    func topLevelAncestor(of session: SessionSummary) -> SessionSummary {
        var current = session
        var seen: Set<String> = [session.id]
        while current.isSubagent, let parent = current.parentSessionId.flatMap({ sessions[$0] }), seen.insert(parent.id).inserted {
            current = parent
        }
        return current
    }

    /// 会话所在的工作区；子 Agent 会话跟着父会话走，其余看自己登记在哪个工作区。
    func workspace(for session: SessionSummary) -> Workspace? {
        let owner = topLevelAncestor(of: session)
        return board.ordered.first { $0.sessionIds.contains(owner.id) }
            ?? owner.cwd.flatMap { cwd in board.ordered.first { $0.path == cwd } }
    }

    /// 最近一次有动静：用户发消息（内核的 updatedAt），或本机看到它开始、结束运行，或刚从归档恢复。
    func lastActive(_ session: SessionSummary) -> Date {
        max(session.updatedAt, touchedAt[session.id] ?? .distantPast)
    }

    /// 自己或子 Agent 在运行。
    func isBusy(_ session: SessionSummary) -> Bool {
        session.running || children(of: session.id).contains(where: \.running)
    }

    /// 自己和子 Agent 的待审批、待回答一起算。
    func pendingCountIncludingChildren(for sessionId: String) -> Int {
        children(of: sessionId).reduce(pendingCount(for: sessionId)) { $0 + pendingCount(for: $1.id) }
    }

    /// 新建面板里的工作区：最近用过的在前，「无项目」（内核的默认工作区）放最后。
    var workspacesByRecent: [Workspace] {
        func lastUsed(_ workspace: Workspace) -> Date {
            workspace.sessionIds.compactMap { sessions[$0]?.updatedAt }.max() ?? .distantPast
        }
        let all = board.ordered.sorted { lastUsed($0) > lastUsed($1) }
        return all.filter { !$0.isDefault } + all.filter(\.isDefault)
    }

    func pendingCount(for sessionId: String) -> Int {
        approvals.count { $0.sessionId == sessionId } + questions.count { $0.sessionId == sessionId }
    }

    // MARK: - 事件

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .emit(let name, let args):
            switch name {
            case "api-session/added":
                if var summary = args.first.flatMap(SessionSummary.init) {
                    if let title = renamedTitles[summary.id] { summary.title = title }
                    sessions[summary.id] = summary
                }
            case "api-session/status":
                if let id = args.first?.stringValue, let running = args.dropFirst().first?.boolValue {
                    if sessions[id]?.running != running, let session = sessions[id] { touch(topLevelAncestor(of: session).id) }
                    sessions[id]?.running = running
                    if !running { scheduleSessionRefresh() }
                }
            case "api-session/activity":
                if let id = args.first?.stringValue, case .number(let millis)? = args.dropFirst().first {
                    sessions[id]?.updatedAt = Date(timeIntervalSince1970: millis / 1000)
                    // 首条消息后会话不再是空白，标题（先是回退标题、再是模型标题）随后生成。
                    if sessions[id]?.blank == true {
                        sessions[id]?.blank = false
                        scheduleSessionRefresh()
                    }
                }
            default:
                if name.hasPrefix("api-session/") { scheduleSessionRefresh() }
            }
        case .waterfall(let name, let eventId, let agentId, let request):
            switch name {
            case "approval/request":
                approvals.append(PendingApproval(
                    eventId: eventId, sessionId: agentId,
                    toolName: request["toolName"]?.stringValue ?? "工具",
                    reason: request["displayReason"]?["zh"]?.stringValue ?? request["reason"]?.stringValue ?? ""
                ))
            case "user-questions/request":
                let items = (request["questions"]?.arrayValue ?? []).compactMap { question -> PendingQuestion.Item? in
                    guard let id = question["id"]?.stringValue, let text = question["question"]?.stringValue else { return nil }
                    let options = (question["options"]?.arrayValue ?? []).compactMap { option -> (String, String?)? in
                        option["label"]?.stringValue.map { ($0, option["description"]?.stringValue) }
                    }
                    return PendingQuestion.Item(
                        id: id, header: question["header"]?.stringValue, question: text,
                        options: options, multiSelect: question["multi_select"]?.boolValue ?? false
                    )
                }
                questions.append(PendingQuestion(eventId: eventId, sessionId: agentId, items: items))
            default:
                // 不认识的 waterfall 交给后续处理者，避免内核一直等。
                Task { try? await connection?.answerEvent(eventId: eventId, result: nil) }
            }
        case .cancel(let eventId):
            approvals.removeAll { $0.eventId == eventId }
            questions.removeAll { $0.eventId == eventId }
        }
    }

    // MARK: - 操作

    /// 添加工作区；`thenNewSession` 时等它出现在工作区列表里后直接新建一个会话。
    func addWorkspace(path: String, thenNewSession: Bool = false) async {
        guard let connection else { return }
        do {
            let value = try await connection.call("workspace/create", ["request": ["path": .string(path)]])
            guard thenNewSession else { return }
            // 内核建好才返回，直接用返回的工作区新建，不等工作区列表推过来。
            guard let workspace = value["workspace"].flatMap(WorkspaceBoard.decode) else {
                lastError = "工作区已添加，但没能在里面新建会话"
                return
            }
            await newSession(in: workspace)
        } catch {
            report(error)
        }
    }

    func newSession(in workspace: Workspace) async {
        guard let connection else { return }
        do {
            let value = try await connection.call("session/create", ["request": ["workspaceId": .string(workspace.id)]])
            if let id = value["sessionId"]?.stringValue {
                try? await refreshSessions()
                selectedSessionId = id
            }
        } catch {
            report(error)
        }
    }

    // MARK: - 归档

    /// 本机看到的最近动静（运行开始、结束，从归档恢复），补内核 updatedAt 只记用户消息的不足；只用来排序。
    private(set) var touchedAt: [String: Date] = [:]
    private let touchedKey: String

    private func touch(_ sessionId: String) {
        touchedAt[sessionId] = Date()
        saveTouched()
    }

    private func saveTouched() {
        UserDefaults.standard.set(touchedAt.mapValues(\.timeIntervalSince1970), forKey: touchedKey)
    }

    /// 手动归档：内核会顺带取消置顶。
    @discardableResult
    func archive(_ sessionId: String) async -> Bool {
        guard let connection else { return false }
        do {
            _ = try await connection.call("workspace/archiveSession", ["request": ["sessionId": .string(sessionId)]])
            return true
        } catch let failure as RemoteFailure where failure.code == "workspace/session-active" {
            lastError = Self.activeMessage(failure.details?["activity"])
        } catch {
            report(error)
        }
        return false
    }

    /// 内核说「还有活动」时，按活动的种类说清楚为什么不能归档。
    private static func activeMessage(_ activity: JSONValue?) -> String {
        let kinds = Set(activity?.arrayValue?.compactMap { $0["kind"]?.stringValue } ?? [])
        if kinds.contains("turn") { return "会话还在运行，停止后再归档" }
        if kinds.contains("schedule") { return "会话有定时任务，暂时不能归档" }
        if !kinds.isEmpty { return "会话还有任务在跑，暂时不能归档" }
        return "会话还在运行，暂时不能归档"
    }

    /// 从归档恢复：成功后记一次动静，排到时间线最上面。
    @discardableResult
    func unarchive(_ sessionId: String) async -> Bool {
        guard let connection else { return false }
        do {
            _ = try await connection.call("workspace/unarchiveSession", ["request": ["sessionId": .string(sessionId)]])
            touch(sessionId)
            return true
        } catch {
            report(error)
            return false
        }
    }

    func togglePin(_ sessionId: String) async {
        guard let connection else { return }
        let method = isPinned(sessionId) ? "workspace/unpinSession" : "workspace/pinSession"
        do { _ = try await connection.call(method, ["request": ["sessionId": .string(sessionId)]]) } catch { report(error) }
    }

    // MARK: - 重命名、分叉、搜索

    /// 本次运行里改过名的会话（列表投影可能还是旧标题）。
    private var renamedTitles: [String: String] = [:]

    func rename(_ sessionId: String, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let connection, !title.isEmpty, title != sessions[sessionId]?.title else { return }
        let previous = sessions[sessionId]?.title
        sessions[sessionId]?.title = title
        renamedTitles[sessionId] = title
        do {
            // 内核会把标题规整一遍（去空白、截长），以它返回的为准。
            let value = try await connection.call("session/rename", ["request": ["sessionId": .string(sessionId), "title": .string(title)]])
            if let accepted = value["title"]?.stringValue {
                renamedTitles[sessionId] = accepted
                sessions[sessionId]?.title = accepted
            }
        } catch {
            renamedTitles[sessionId] = nil
            sessions[sessionId]?.title = previous
            report(error)
        }
    }

    /// 从最后一个完成的回合分叉出一个独立会话并选中它。
    func fork(_ sessionId: String) async -> String? {
        guard let connection else { return nil }
        do {
            let value = try await connection.call("session/fork", ["request": ["sessionId": .string(sessionId)]])
            guard let id = value["sessionId"]?.stringValue else { return nil }
            try? await refreshSessions()
            selectedSessionId = id
            return id
        } catch let failure as RemoteFailure where failure.code == "session/fork-unavailable" {
            lastError = "还没有完成的回合，暂时不能分叉"
        } catch {
            report(error)
        }
        return nil
    }

    struct SearchHit: Identifiable, Equatable {
        var id: String { sessionId }
        let sessionId: String
        let snippet: String
    }

    /// 内核没开会话索引（DSH 默认 `openAt: never`）时正文搜索不可用，之后只搜标题。
    private(set) var contentSearchAvailable = true

    /// 正文搜索：内核最多给 20 条，每条一段原文。
    func searchContent(_ query: String) async throws -> [SearchHit] {
        guard let connection, contentSearchAvailable else { return [] }
        let value: JSONValue
        do {
            value = try await connection.call("session/search", ["request": ["query": .string(query)]])
        } catch let failure as RemoteFailure where failure.message.contains("search is disabled") {
            contentSearchAvailable = false
            return []
        }
        return (value["items"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["sessionId"]?.stringValue, let snippet = item["snippet"]?.stringValue else { return nil }
            return SearchHit(sessionId: id, snippet: snippet)
        }
    }

    /// 发消息；返回是否发出去了（没发出去时输入框保留草稿）。
    @discardableResult
    func send(_ text: String, to sessionId: String) async -> Bool {
        guard let connection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // 在归档的会话里发消息，它就回到主列表；恢复失败就不发，内核会拦下归档会话的回合。
        if board.archivedSessionIds.contains(sessionId) {
            guard await unarchive(sessionId) else { return false }
        }
        do {
            _ = try await connection.call("session/prompt", ["request": [
                "requestId": .string(UUID().uuidString),
                "sessionId": .string(sessionId),
                "mode": "queue",
                "content": .array([["type": "text", "text": .string(text)]]),
                "clientTimeZone": .string(TimeZone.current.identifier),
            ]])
            return true
        } catch {
            report(error)
            return false
        }
    }

    func cancel(sessionId: String) async {
        guard let connection else { return }
        do { _ = try await connection.call("session/cancel", ["request": ["sessionId": .string(sessionId)]]) } catch { report(error) }
    }

    func selectModel(_ choice: ModelChoice, effort: String?, for sessionId: String) async {
        guard let connection else { return }
        var request: [String: JSONValue] = [
            "sessionId": .string(sessionId), "provider": .string(choice.provider), "model": .string(choice.model),
        ]
        if let effort { request["reasoningEffort"] = .string(effort) }
        do {
            _ = try await connection.call("session/selectModel", ["request": .object(request)])
            conversations[sessionId]?.modelOverride = (choice, effort)
        } catch {
            report(error)
        }
    }

    func answer(_ approval: PendingApproval, allow: Bool) async {
        approvals.removeAll { $0.eventId == approval.eventId }
        do {
            try await connection?.answerEvent(eventId: approval.eventId, result: .string(allow ? "allowed-once" : "rejected"))
        } catch {
            report(error)
        }
    }

    func answer(_ question: PendingQuestion, selections: [String: [String]], custom: [String: String]) async {
        questions.removeAll { $0.eventId == question.eventId }
        let answers: [JSONValue] = question.items.map { item in
            var answer: [String: JSONValue] = [
                "id": .string(item.id),
                "selected": .array((selections[item.id] ?? []).map(JSONValue.string)),
            ]
            if let text = custom[item.id], !text.isEmpty { answer["custom"] = .string(text) }
            return .object(answer)
        }
        do {
            try await connection?.answerEvent(eventId: question.eventId, result: ["answers": .array(answers)])
        } catch {
            report(error)
        }
    }

    // MARK: - 模型目录

    private func loadModels() async throws {
        guard let connection else { return }
        let catalog = try await connection.call("session/modelCatalog")
        models = (catalog["groups"]?.arrayValue ?? []).flatMap { group -> [ModelChoice] in
            let provider = group["id"]?.stringValue ?? ""
            let groupName = group["name"]?.stringValue ?? provider
            return (group["models"]?.arrayValue ?? []).compactMap { model in
                guard let id = model["id"]?.stringValue else { return nil }
                return ModelChoice(
                    provider: provider, model: id, name: model["name"]?.stringValue ?? id, group: groupName,
                    efforts: model["reasoning"]?["efforts"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? [],
                    defaultEffort: model["reasoning"]?["defaultEffort"]?.stringValue
                )
            }
        }
        let fallback = catalog["default"]
        defaultModel = models.first {
            $0.provider == fallback?["provider"]?.stringValue && $0.model == fallback?["model"]?.stringValue
        } ?? models.first
    }

    /// 改了默认模型、API Key 或账号后重读模型目录。
    func reloadModels() async {
        do { try await loadModels() } catch { report(error) }
    }

    // MARK: - 会话

    /// 只为正在显示的会话保持跟读：新出现的打开，不再显示的关掉。
    func retainConversations(_ ids: Set<String>) {
        wantedConversations = ids
        for (id, conversation) in conversations where !ids.contains(id) {
            conversation.close()
            conversations[id] = nil
        }
        guard let connection, phase == .ready else { return }
        for id in ids where conversations[id] == nil {
            let summary = sessions[id]
            let conversation = ConversationModel(sessionId: id, parentSessionId: summary?.isSubagent == true ? summary?.parentSessionId : nil)
            conversations[id] = conversation
            conversation.open(on: connection)
        }
    }

    private(set) var lastError: String?

    private func report(_ error: Error) {
        if let failure = error as? RemoteFailure {
            lastError = failure.message.isEmpty ? failure.code : failure.message
        } else {
            lastError = String(describing: error)
        }
    }

    func dismissError() { lastError = nil }
}
