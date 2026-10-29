import AppKit
import Foundation
import Observation
import WestieKit

/// 设置卡片里写进内核的那部分：新会话默认、权限、账号与 API Key、子代理、会话日志。
/// 读 `settings/describe`，写 `settings/update`（只合并改动的字段到用户层）；账号走 `account/*`，密钥走 `credentials/*`。
@MainActor @Observable
final class SettingsModel {
    struct DefaultModel: Equatable {
        var provider: String
        var model: String
        var effort: String?
    }

    enum Account: Equatable {
        case unknown
        case signedOut
        /// 正在浏览器里登录。
        case signingIn
        case signedIn(name: String?, balance: String?)
    }

    /// DeepSeek 模型和联网搜索共用这一个密钥引用（`llm-deepseek.apiKeyEnv`）。
    static let apiKeyRef = "DEEPSEEK_API_KEY"
    static let presets = [("workspace-write", "越界时询问"), ("danger-full-access", "完全访问")]

    /// 设置卡片当前的分页。
    var tab: SettingsTab = .general
    /// 外观页的字体是否展开了逐项自定义。
    var fontsExpanded = false
    private(set) var loaded = false
    private(set) var writable = true
    private(set) var defaultModel: DefaultModel?
    private(set) var permissionPreset = "workspace-write"
    private(set) var sessionLog = true
    private(set) var maxDepth = 1
    private(set) var maxActive = 8
    private(set) var account: Account = .unknown
    private(set) var apiKeyConfigured = false
    private(set) var error: String?

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var attemptId: String?

    private var connection: KernelConnection? { app?.connection }

    private var client: JSONValue {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [
            "version": .string(version),
            "locale": .string(Locale.preferredLanguages.first ?? "zh-CN"),
            "timezoneOffsetSeconds": .number(Double(TimeZone.current.secondsFromGMT())),
        ]
    }

    // MARK: - 读

    func load() async {
        guard let connection else { return }
        do {
            let described = try await connection.call("settings/describe")
            writable = described["writable"]?.boolValue ?? true
            for namespace in described["namespaces"]?.arrayValue ?? [] {
                guard let ns = namespace["ns"]?.stringValue, let value = namespace["value"] else { continue }
                read(ns, value)
            }
            let credentials = try await connection.call("credentials/describe", ["refs": .array([.string(Self.apiKeyRef)])])
            apiKeyConfigured = credentials[Self.apiKeyRef]?["configured"]?.boolValue ?? false
            loaded = true
            error = nil
        } catch {
            report(error)
        }
        await loadAccount()
    }

    private func read(_ ns: String, _ value: JSONValue) {
        switch ns {
        case "agent-default-model":
            if let provider = value["provider"]?.stringValue, let model = value["model"]?.stringValue {
                defaultModel = DefaultModel(provider: provider, model: model, effort: value["reasoningEffort"]?.stringValue)
            }
        case "permission":
            if let preset = value["defaultPreset"]?.stringValue, !preset.isEmpty { permissionPreset = preset }
        case "session-log-deepseek":
            sessionLog = value["enabled"]?.boolValue ?? true
        case "subagent":
            if case .number(let depth)? = value["maxDepth"] { maxDepth = Int(depth) }
            if case .number(let active)? = value["maxActiveSubagents"] { maxActive = Int(active) }
        default:
            break
        }
    }

    private func loadAccount() async {
        guard let connection else { return }
        do {
            let state = try await connection.call("account/getState")
            guard state["status"]?.stringValue == "credential-stored" else {
                if case .signingIn = account { return }
                account = .signedOut
                return
            }
            async let profile = connection.call("account/getProfile", ["client": client])
            async let balance = connection.call("account/getBalance", ["client": client])
            let (profileValue, balanceValue) = try await (profile, balance)
            let info = profileValue["value"]
            let name = info?["name"]?.stringValue ?? info?["contact"]?.stringValue
            account = .signedIn(name: name, balance: Self.formatBalance(balanceValue["value"]))
        } catch {
            report(error)
        }
    }

    private static func formatBalance(_ wallets: JSONValue?) -> String? {
        guard let first = wallets?.arrayValue?.first(where: { $0["currency"]?.stringValue == "CNY" }) ?? wallets?.arrayValue?.first,
              let amount = first["balance"]?.stringValue
        else { return nil }
        return (first["currency"]?.stringValue == "USD" ? "$ " : "¥ ") + amount
    }

    // MARK: - 写

    func setDefaultModel(_ choice: ModelChoice, effort: String?) async {
        var patch: [String: JSONValue] = ["provider": .string(choice.provider), "model": .string(choice.model)]
        if let effort { patch["reasoningEffort"] = .string(effort) }
        defaultModel = DefaultModel(provider: choice.provider, model: choice.model, effort: effort)
        await update("agent-default-model", .object(patch))
        await app?.reloadModels()
    }

    func setPermission(_ preset: String) async {
        permissionPreset = preset
        await update("permission", ["defaultPreset": .string(preset)])
    }

    func setSessionLog(_ enabled: Bool) async {
        sessionLog = enabled
        await update("session-log-deepseek", ["enabled": .bool(enabled)])
    }

    func setMaxDepth(_ value: Int) async {
        maxDepth = max(0, value)
        await update("subagent", ["maxDepth": .number(Double(maxDepth))])
    }

    func setMaxActive(_ value: Int) async {
        maxActive = max(1, value)
        await update("subagent", ["maxActiveSubagents": .number(Double(maxActive))])
    }

    func openSettingsDocument() async {
        guard let connection else { return }
        do { _ = try await connection.call("settings/openSettingsDocument") } catch { report(error) }
    }

    private func update(_ ns: String, _ patch: JSONValue) async {
        guard let connection else { return }
        do {
            let view = try await connection.call("settings/update", ["ns": .string(ns), "patch": patch])
            if let value = view["value"] { read(ns, value) }
        } catch {
            report(error)
            await load()
        }
    }

    // MARK: - API Key

    func setAPIKey(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let connection, !trimmed.isEmpty else { return }
        do {
            _ = try await connection.call("credentials/set", ["ref": .string(Self.apiKeyRef), "value": .string(trimmed)])
            apiKeyConfigured = true
            await app?.reloadModels()
        } catch {
            report(error)
        }
    }

    func removeAPIKey() async {
        guard let connection else { return }
        do {
            _ = try await connection.call("credentials/unset", ["ref": .string(Self.apiKeyRef)])
            apiKeyConfigured = false
            await app?.reloadModels()
        } catch {
            report(error)
        }
    }

    // MARK: - 账号

    /// 在浏览器里登录：内核给出授权地址，回调落在内核自己的 HTTP 服务上；这边轮询状态直到结束。
    func signIn() async {
        guard let connection else { return }
        do {
            let state = try await connection.call("account/startSignIn", [
                "client": client,
                "callbackOrigin": .string(connection.endpoint.origin.absoluteString),
                "loginSource": "desktop",
            ])
            attemptId = state["attempt"]?["id"]?.stringValue
            if let link = state["attempt"]?["authorizeUrl"]?.stringValue, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
            account = .signingIn
            watchSignIn()
        } catch {
            report(error)
        }
    }

    func cancelSignIn() async {
        signInTask?.cancel()
        if let attemptId { _ = try? await connection?.call("account/cancelSignIn", ["attemptId": .string(attemptId)]) }
        attemptId = nil
        account = .signedOut
    }

    func signOut() async {
        guard let connection else { return }
        do {
            _ = try await connection.call("account/signOut", ["client": client])
            account = .signedOut
            await app?.reloadModels()
        } catch {
            report(error)
        }
    }

    private func watchSignIn() {
        signInTask?.cancel()
        signInTask = Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let connection = self.connection else { return }
                guard let state = try? await connection.call("account/getState") else { continue }
                if state["status"]?.stringValue == "credential-stored" {
                    self.account = .unknown
                    await self.loadAccount()
                    await self.app?.reloadModels()
                    return
                }
                let phase = state["attempt"]?["phase"]?.stringValue
                if state["attempt"] == .null || ["cancelled", "expired", "failed"].contains(phase ?? "") {
                    self.account = .signedOut
                    return
                }
            }
        }
    }

    private func report(_ error: Error) {
        if let failure = error as? RemoteFailure {
            self.error = failure.message.isEmpty ? failure.code : failure.message
        } else {
            self.error = String(describing: error)
        }
    }

    func dismissError() { error = nil }
}
