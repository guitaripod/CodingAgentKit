import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private func session(_ id: String, parent: String? = nil) -> AgentSession {
    AgentSession(
        id: id, agentType: .openCode, title: id, parentID: parent,
        createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
}

@Suite struct SubagentSessionListingTests {
    @Test func parentedSessionIsASubagent() {
        #expect(session("child", parent: "parent").isSubagent)
        #expect(!session("parent").isSubagent)
    }

    @Test func conversationListingDropsSpawnedAgents() async throws {
        let backend = MockBackend(
            sessions: [session("parent"), session("child", parent: "parent")])
        let conversations = try await backend.listAllSessions(knownDirectories: [])
        #expect(conversations.map(\.id) == ["parent"])
    }

    @Test func literalListingKeepsThemSoSpendStaysCounted() async throws {
        let backend = MockBackend(
            sessions: [session("parent"), session("child", parent: "parent")])
        let listed = try await backend.listSessions()
        #expect(listed.map(\.id) == ["parent", "child"])
    }
}
