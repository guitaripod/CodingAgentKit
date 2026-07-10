import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0,
    pollFallbackAfterFailures: nil
)

private func assistant(_ id: String, _ text: String) -> BackendEvent {
    .messageUpserted(
        ChatMessage(
            id: id, role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: id + "-p", kind: .text(text))],
            createdAt: Date(timeIntervalSince1970: 0)),
        replaceParts: true)
}

@Suite struct AgentConversationTests {
    @Test func foldsStatusPermissionAndMessagesIntoState() async {
        let permission = PermissionRequest(id: "perm1", sessionID: "s", toolName: "bash")
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(assistant("a", "hi")),
                MockScriptStep(.permission(permission)),
                MockScriptStep(.status(.running)),
                MockScriptStep(.status(.idle)),
            ])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var observed: ConversationState?
        for await state in await conversation.states() where state.status == .idle {
            observed = state
            break
        }

        #expect(observed?.messages.first?.text == "hi")
        #expect(observed?.pendingPermissions.map(\.id) == ["perm1"])
        #expect(observed?.status == .idle)
    }

    @Test func reconnectsAfterMidStreamDrop() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistant("a", "hi")), MockScriptStep(.status(.idle))],
            failAfter: 1)
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var sawReconnecting = false
        var recovered: ConversationState?
        for await state in await conversation.states() {
            if state.connection == .reconnecting { sawReconnecting = true }
            if state.status == .idle {
                recovered = state
                break
            }
        }

        #expect(sawReconnecting)
        #expect(recovered?.messages.first?.text == "hi")
    }

    @Test func loadsExistingHistoryBeforeStreaming() async {
        // The only event is delayed far beyond the test, so any history must come from messages().
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistant("m", "hello"), delay: .seconds(60))])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var loaded: ConversationState?
        for await state in await conversation.states() where state.messages.first?.text == "hello" {
            loaded = state
            break
        }
        #expect(loaded?.messages.first?.text == "hello")
    }

    @Test func infersRunningFromStreamingWithoutExplicitStatus() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(assistant("a", "part")),
                MockScriptStep(.partTextDelta(messageID: "a", partID: "a-p", delta: "ial")),
                MockScriptStep(.status(.idle), delay: .milliseconds(20)),
            ])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var sawRunning = false
        for await state in await conversation.states() {
            if state.status == .running { sawRunning = true }
            if state.status == .idle && sawRunning { break }
        }
        #expect(sawRunning)
    }

    @Test func respondClearsPendingPermission() async throws {
        let permission = PermissionRequest(id: "perm1", sessionID: "s", toolName: "bash")
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(.permission(permission), delay: .milliseconds(5))])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var responded = false
        for await state in await conversation.states() {
            if !responded, let pending = state.pendingPermissions.first {
                responded = true
                try await conversation.respond(to: pending, decision: .once)
                continue
            }
            if responded && state.pendingPermissions.isEmpty { break }
        }

        let pending = await conversation.state.pendingPermissions
        #expect(responded)
        #expect(pending.isEmpty)
    }
}
