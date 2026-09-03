import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private let slowReconnectPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(300),
    reconnectMaxDelay: .milliseconds(300),
    reconnectJitter: 0
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
        for await state in await conversation.states()
        where state.status == .idle && !state.pendingPermissions.isEmpty {
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
            script: [
                MockScriptStep(.status(.running)),
                MockScriptStep(assistant("a", "hi")),
                MockScriptStep(.status(.idle)),
            ],
            failAfter: 1)
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: slowReconnectPolicy)

        var sawReconnecting = false
        var recovered: ConversationState?
        for await state in await conversation.states() {
            if state.connection == .reconnecting { sawReconnecting = true }
            if sawReconnecting, state.status == .idle {
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

    @Test func marksTranscriptLoadedOnceHistoryArrives() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistant("m", "hello"), delay: .seconds(60))])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        let fresh = await conversation.state
        #expect(fresh.hasLoadedTranscript == false)
        #expect(fresh.isLoadingTranscript)

        var loaded: ConversationState?
        for await state in await conversation.states() where state.hasLoadedTranscript {
            loaded = state
            break
        }
        #expect(loaded?.messages.first?.text == "hello")
        #expect(loaded?.isLoadingTranscript == false)
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

/// A turn can stream for a long time; the cache must not wait for idle. The stream here never
/// reports `.idle`, so anything the cache receives was written mid-turn.
@Suite struct StreamPersistenceTests {
    private actor RecordingCache: SessionCache {
        var stored: [[ChatMessage]] = []
        func sessions(for agentType: AgentType) async -> [AgentSession] { [] }
        func store(_ sessions: [AgentSession], for agentType: AgentType) async {}
        func messages(for sessionID: String) async -> [ChatMessage] { [] }
        func store(_ messages: [ChatMessage], for sessionID: String) async {
            stored.append(messages)
        }
    }

    @Test func aStreamingTurnReachesTheCacheWithoutIdle() async {
        let cache = RecordingCache()
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(assistant("a", "the first words of a long answer")),
                MockScriptStep(.status(.running)),
            ])
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: fastPolicy, cache: cache)

        for await state in await conversation.states()
        where state.messages.first?.text.isEmpty == false {
            break
        }
        var landed = false
        for _ in 0..<100 {
            if await !cache.stored.isEmpty {
                landed = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(landed, "a mid-turn transcript never reached the cache")
        _ = conversation
    }

    @Test func aQueuedPromptLeavesARunningCompactionAlone() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(.compaction(CompactionActivity(startedAt: Date())))])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        for await state in await conversation.states() where state.activeCompaction != nil { break }
        try? await conversation.send("and while you are at it, run the tests")

        #expect(
            await conversation.state.activeCompaction != nil,
            "queueing a prompt took the running compaction off the screen")
    }

    @Test func aCompactionIsOverOnceItsSeamIsInTheTranscript() async {
        let seam = ChatMessage(
            id: "seam", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "c", kind: .compaction(Compaction(tokensBefore: 90_000, tokensAfter: 4_000)))],
            createdAt: Date())
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
                MockScriptStep(.messageUpserted(seam, replaceParts: true), delay: .milliseconds(300)),
            ],
            capabilities: BackendCapabilities(
                supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
                supportsMultipleSessions: true, supportsModelSelection: true,
                supportsAttachments: false, supportsCompaction: true,
                reportsMessageCompletion: false),
            transcriptPrefix: 0)
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var sawRunning = false
        var settled = false
        for await state in await conversation.states() {
            if state.activeCompaction != nil { sawRunning = true }
            if sawRunning, state.activeCompaction == nil,
                state.messages.contains(where: { $0.id == "seam" })
            {
                settled = true
                break
            }
        }
        #expect(sawRunning, "the compaction never showed as running")
        #expect(settled, "a seam in the transcript did not end the compaction the stream never closed")
    }

    @Test func aSeamStillBeingWrittenDoesNotEndTheCompaction() async {
        let streaming = ChatMessage(
            id: "seam", role: .system, agentType: .openCode,
            parts: [MessagePart(id: "c", kind: .compaction(Compaction(summary: "so far")))],
            createdAt: Date(), completedAt: nil, isStreaming: true)
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
                MockScriptStep(.messageUpserted(streaming, replaceParts: true), delay: .milliseconds(300)),
            ],
            transcriptPrefix: 0)
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        var stillRunning: Bool?
        for await state in await conversation.states()
        where state.messages.contains(where: { $0.id == "seam" }) {
            stillRunning = state.activeCompaction != nil
            break
        }
        #expect(
            stillRunning == true,
            "a summary still streaming into its seam took the compaction card down early")
    }

    @Test func aNewPromptDropsTheLastCompactionsFailure() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(
                    .compaction(
                        CompactionActivity(startedAt: Date(), failure: "Nothing to compact.")))
            ])
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)

        for await state in await conversation.states() where state.compaction != nil { break }
        try? await conversation.send("never mind, carry on")

        #expect(await conversation.state.compaction == nil)
    }
}
