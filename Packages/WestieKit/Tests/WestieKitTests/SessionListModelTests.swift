import Testing
@testable import WestieKit

struct SessionListModelTests {
    @Test func defaultWorkspaceNeedsFullLocation() {
        let real = Workspace(id: "a", path: Workspace.defaultPath, title: "default-workspace", sessionIds: [])
        let lookalike = Workspace(id: "b", path: "/work/deepseek-harness/default-workspace", title: "default-workspace", sessionIds: [])
        let renamed = Workspace(id: "c", path: real.path, title: "随手记", sessionIds: [])
        #expect(real.isDefault && real.displayTitle == "无项目")
        #expect(!lookalike.isDefault && lookalike.displayTitle == "default-workspace")
        #expect(renamed.isDefault && renamed.displayTitle == "随手记")
    }

    @Test func forkIsNotSubagent() throws {
        let fork = try #require(SessionSummary(["sessionId": "f", "parentSessionId": "p"]))
        let child = try #require(SessionSummary(["sessionId": "c", "parentSessionId": "p", "origin": "subagent"]))
        #expect(!fork.isSubagent)
        #expect(child.isSubagent)
    }

    @Test func baselineKeepsPinOrder() {
        var board = WorkspaceBoard()
        board.apply(["type": "baseline", "value": ["items": .array([]), "archivedSessionIds": .array([]), "pinnedSessionIds": .array(["s2", "s1"])]])
        #expect(board.pinnedSessionIds == ["s2", "s1"])
    }
}
