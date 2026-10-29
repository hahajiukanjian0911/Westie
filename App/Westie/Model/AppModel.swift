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
        sessions = next
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

    /// 某个工作区下要显示的会话（排除已归档、子 Agent 会话和没发过消息的空会话），按最近活动排序。
    /// 空会话只在正选中时显示，发出第一条消息后就是正常会话。
    func sessions(in workspace: Workspace) -> [SessionSummary] {
        workspace.sessionIds
            .filter { !board.archivedSessionIds.contains($0) }
            .compactMap { sessions[$0] }
            .filter { $0.parentSessionId == nil && (!$0.blank || $0.id == selectedSessionId) }
            .sorted { $0.updatedAt > $1.updatedAt }
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
                if let summary = args.first.flatMap(SessionSummary.init) { sessions[summary.id] = summary }
            case "api-session/status":
                if let id = args.first?.stringValue, let running = args.dropFirst().first?.boolValue {
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

    func addWorkspace(path: String) async {
        guard let connection else { return }
        do {
            _ = try await connection.call("workspace/create", ["request": ["path": .string(path)]])
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

    func send(_ text: String, to sessionId: String) async {
        guard let connection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            _ = try await connection.call("session/prompt", ["request": [
                "requestId": .string(UUID().uuidString),
                "sessionId": .string(sessionId),
                "mode": "queue",
                "content": .array([["type": "text", "text": .string(text)]]),
                "clientTimeZone": .string(TimeZone.current.identifier),
            ]])
        } catch {
            report(error)
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
            let conversation = ConversationModel(sessionId: id)
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
