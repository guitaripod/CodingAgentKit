import Foundation
import Testing

@testable import AgentCore

@Suite struct CodableTests {
    @Test func chatMessageRoundTripsAllPartKinds() throws {
        let message = ChatMessage(
            id: "m",
            role: .assistant,
            agentType: .openCode,
            parts: [
                MessagePart(id: "t", kind: .text("hi")),
                MessagePart(id: "r", kind: .reasoning("hmm")),
                MessagePart(
                    id: "tool",
                    kind: .tool(
                        ToolCall(
                            id: "c", name: "bash", status: .completed,
                            input: .object(["cmd": .string("ls")]), output: "ok", title: "ls"))),
                MessagePart(id: "f", kind: .file(FileReference(path: "a", mime: "text/plain"))),
                MessagePart(id: "u", kind: .unknown(type: "step-start")),
            ],
            createdAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2))

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded == message)
    }

    @Test func conversationStateRoundTrips() throws {
        let state = ConversationState(
            messages: [
                ChatMessage(
                    id: "m", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "p", kind: .text("hey"))],
                    createdAt: Date(timeIntervalSince1970: 0))
            ],
            status: .running,
            pendingPermissions: [PermissionRequest(id: "perm", sessionID: "s", toolName: "bash")],
            lastFailure: BackendFailure(message: "boom", code: "E", retryable: true),
            connection: .reconnecting)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ConversationState.self, from: data)
        #expect(decoded == state)
    }
}
