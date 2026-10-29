import Foundation
import Observation
import WestieKit

/// 一个打开中的会话：跟读 `session/follow`，把帧折叠进 Transcript。
@MainActor @Observable
final class ConversationModel {
    let sessionId: String
    private(set) var transcript = Transcript()
    private(set) var isLoading = true
    private(set) var hasEarlierHistory = false
    private(set) var isLoadingEarlier = false
    private(set) var earlierError: String?
    private(set) var followError: String?
    /// 会话上次使用 / 下次使用的模型（来自 projections.modelSelection）。
    private(set) var modelSelection: (provider: String, model: String, effort: String?)?
    /// 本次在输入框里选的模型；优先于 modelSelection 显示。
    var modelOverride: (choice: ModelChoice, effort: String?)?

    private var followTask: Task<Void, Never>?
    private var earlierTask: Task<Bool, Never>?
    private var connection: KernelConnection?
    /// 跟读开场快照的日志截点；往前翻页都以它为 throughSeq，保证各页拼起来连续。
    private var historyCursor: Int?

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func open(on connection: KernelConnection) {
        self.connection = connection
        followTask = Task { [weak self, sessionId] in
            let stream = await connection.stream("session/follow", ["request": [
                "address": ["kind": "session", "sessionId": .string(sessionId)],
                "assistantStream": true,
                "maxMessages": .number(200),
            ]])
            do {
                for try await frame in stream {
                    guard let self else { return }
                    if frame["type"]?.stringValue == "snapshot" {
                        self.isLoading = false
                        if self.historyCursor == nil {
                            self.hasEarlierHistory = frame["hasMore"]?.boolValue ?? false
                            if case .number(let cursor) = frame["cursor"] { self.historyCursor = Int(cursor) }
                        }
                        self.readModelSelection(frame["projections"]?["values"]?["modelSelection"])
                    }
                    self.transcript.apply(followFrame: frame)
                }
            } catch {
                self?.followError = (error as? RemoteFailure)?.message ?? String(describing: error)
                self?.isLoading = false
            }
        }
    }

    /// 往前加载一页历史（与 DSH 网页版同样的分页参数：至少 50 条消息、跨过 2 个回合，最多 500 条）。
    /// 已有请求在途时等它结束并返回它的结果，不另发请求。返回是否真的接上了更早的记录。
    @discardableResult
    func loadEarlier() async -> Bool {
        if let earlierTask { return await earlierTask.value }
        guard hasEarlierHistory, let connection, let historyCursor,
              let beforeSeq = transcript.firstSeq else { return false }
        isLoadingEarlier = true
        earlierError = nil
        let task = Task { await fetchEarlier(connection: connection, throughSeq: historyCursor, beforeSeq: beforeSeq) }
        earlierTask = task
        let loaded = await task.value
        earlierTask = nil
        isLoadingEarlier = false
        return loaded
    }

    private func fetchEarlier(connection: KernelConnection, throughSeq: Int, beforeSeq: Int) async -> Bool {
        do {
            let page = try await connection.call("session/page", ["request": [
                "address": ["kind": "session", "sessionId": .string(sessionId)],
                "throughSeq": .number(Double(throughSeq)),
                "beforeSeq": .number(Double(beforeSeq)),
                "maxMessages": .number(500),
                "turnWindow": ["minMessages": .number(50), "minTurns": .number(2)],
            ]])
            transcript.prepend(pageRecords: page["records"]?.arrayValue ?? [])
            let loaded = (transcript.firstSeq ?? beforeSeq) < beforeSeq
            // 没拿到更早的记录却仍说还有，也停下，免得反复空翻。
            hasEarlierHistory = (page["hasMore"]?.boolValue ?? false) && loaded
            return loaded
        } catch {
            earlierError = (error as? RemoteFailure)?.message ?? String(describing: error)
            return false
        }
    }

    func close() {
        followTask?.cancel()
        followTask = nil
    }

    private func readModelSelection(_ value: JSONValue?) {
        guard let pick = value?["next"].flatMap({ $0 == .null ? nil : $0 }) ?? value?["lastUsed"],
              let provider = pick["provider"]?.stringValue, let model = pick["model"]?.stringValue
        else { return }
        modelSelection = (provider, model, pick["reasoningEffort"]?.stringValue)
    }
}
