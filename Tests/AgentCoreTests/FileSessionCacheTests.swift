import Foundation
import Testing

@testable import AgentCore

@Suite struct FileSessionCacheTests {
    @Test func roundTripsMessagesAndSessions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cak-cache-test-A")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir)

        let session = AgentSession(
            id: "ses_1", agentType: .openCode, title: "Test",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 1))
        await cache.store([session], for: .openCode)

        let messages = [
            ChatMessage(
                id: "m", role: .assistant, agentType: .openCode,
                parts: [MessagePart(id: "p", kind: .text("cached"))],
                createdAt: Date(timeIntervalSince1970: 0))
        ]
        await cache.store(messages, for: "ses_1")

        let reloaded = try FileSessionCache(directory: dir)
        #expect(await reloaded.sessions(for: .openCode) == [session])
        #expect(await reloaded.messages(for: "ses_1").first?.text == "cached")
    }
}
