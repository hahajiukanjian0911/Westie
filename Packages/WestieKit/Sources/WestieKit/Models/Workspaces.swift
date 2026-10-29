import Foundation

public struct Workspace: Sendable, Identifiable, Hashable {
    public var id: String
    public var path: String
    public var title: String
    public var sessionIds: [String]

    /// 内核首次启动时建的默认工作区（`…/deepseek-harness/default-workspace`），界面上叫「无项目」。
    public var isDefault: Bool { URL(filePath: path).lastPathComponent == "default-workspace" }

    public var displayTitle: String { isDefault ? "无项目" : title }
}

/// `workspace/follow` 的本地投影：baseline 之后按顺序应用增量帧。
public struct WorkspaceBoard: Sendable, Equatable {
    public private(set) var workspaces: [String: Workspace] = [:]
    public private(set) var order: [String] = []
    public private(set) var archivedSessionIds: Set<String> = []
    public private(set) var pinnedSessionIds: [String] = []

    public init() {}

    public var ordered: [Workspace] {
        let known = order.compactMap { workspaces[$0] }
        let rest = workspaces.values.filter { !order.contains($0.id) }.sorted { $0.title < $1.title }
        return known + rest
    }

    public mutating func apply(_ frame: JSONValue) {
        switch frame["type"]?.stringValue {
        case "baseline", "replace":
            guard let value = frame["value"] else { return }
            workspaces = [:]
            order = []
            for item in value["items"]?.arrayValue ?? [] {
                if let workspace = Self.decode(item) {
                    workspaces[workspace.id] = workspace
                    order.append(workspace.id)
                }
            }
            archivedSessionIds = Set(value["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            pinnedSessionIds = value["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        case "upsert":
            if let workspace = frame["workspace"].flatMap(Self.decode) {
                if workspaces[workspace.id] == nil, !order.contains(workspace.id) { order.append(workspace.id) }
                workspaces[workspace.id] = workspace
            }
        case "remove":
            if let id = frame["workspaceId"]?.stringValue {
                workspaces[id] = nil
                order.removeAll { $0 == id }
            }
        case "order":
            order = frame["workspaceIds"]?.arrayValue?.compactMap(\.stringValue) ?? order
        case "archived":
            archivedSessionIds = Set(frame["archivedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        case "pinned":
            pinnedSessionIds = frame["pinnedSessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        default:
            break
        }
    }

    static func decode(_ value: JSONValue) -> Workspace? {
        guard let id = value["workspaceId"]?.stringValue, let path = value["path"]?.stringValue else { return nil }
        return Workspace(
            id: id, path: path,
            title: value["title"]?.stringValue ?? URL(filePath: path).lastPathComponent,
            sessionIds: value["sessionIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

/// 侧栏一行会话：来自 `session/list` 与 `api-session/added`。
public struct SessionSummary: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String?
    public var running: Bool
    public var blank: Bool
    public var updatedAt: Date
    public var cwd: String?
    public var parentSessionId: String?

    public init?(_ value: JSONValue) {
        guard let id = value["sessionId"]?.stringValue else { return nil }
        self.id = id
        title = value["projections"]?["values"]?["title"]?.stringValue
        running = value["running"]?.boolValue ?? false
        blank = value["blank"]?.boolValue ?? false
        if case .number(let millis) = value["updatedAt"] {
            updatedAt = Date(timeIntervalSince1970: millis / 1000)
        } else {
            updatedAt = .distantPast
        }
        cwd = value["cwd"]?.stringValue
        parentSessionId = value["parentSessionId"]?.stringValue
    }

    public var displayTitle: String { title ?? (blank ? "新会话" : "未命名会话") }
}
