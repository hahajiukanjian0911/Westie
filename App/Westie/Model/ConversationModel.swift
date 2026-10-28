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
    private(set) var followError: String?
    /// 会话上次使用 / 下次使用的模型（来自 projections.modelSelection）。
    private(set) var modelSelection: (provider: String, model: String, effort: String?)?
    /// 本次在输入框里选的模型；优先于 modelSelection 显示。
    var modelOverride: (choice: ModelChoice, effort: String?)?

    private var followTask: Task<Void, Never>?

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func open(on connection: KernelConnection) {
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
                        self.hasEarlierHistory = frame["hasMore"]?.boolValue ?? false
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
