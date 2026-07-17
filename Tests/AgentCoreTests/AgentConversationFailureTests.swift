import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let terminalPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(1),
    reconnectMaxDelay: .milliseconds(4),
    reconnectJitter: 0
)

private let exhaustPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(1),
    reconnectMaxDelay: .milliseconds(4),
    reconnectJitter: 0,
    maxReconnectAttempts: 2
)

private let recoveryPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private func assistantEvent(_ id: String, _ text: String) -> BackendEvent {
    .messageUpserted(
        ChatMessage(
            id: id, role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: id + "-p", kind: .text(text))],
            createdAt: Date(timeIntervalSince1970: 0)),
        replaceParts: true)
}

/// A backend whose event stream throws a chosen ``AgentError`` on every subscription, so the
/// reconnect loop's retryability handling can be exercised without ``MockBackend``'s one-shot
/// `failAfter` (which only fails the first subscription and then recovers).
private struct StreamErrorBackend: CodingAgentBackend {
    let agentType: AgentType = .openCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: false, supportsModelSelection: false, supportsAttachments: false)
    let streamError: AgentError

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "err", agentType: agentType, title: title ?? "err",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let streamError = streamError
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: streamError)
        }
    }
}

/// Races an async `ConversationState` producer against a wall-clock deadline so a regressed
/// recovery path fails the assertion instead of hanging the suite forever.
private func firstState(
    within timeout: Duration,
    _ operation: @escaping @Sendable () async -> ConversationState?
) async -> ConversationState? {
    await withTaskGroup(of: ConversationState?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@Suite struct AgentConversationFailureTests {
    @Test func nonRetryableStreamErrorGoesOfflineAndStopsRetrying() async {
        let backend = StreamErrorBackend(streamError: .http(status: 401, body: ""))
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: terminalPolicy)

        var states: [ConversationState] = []
        for await state in await conversation.states() {
            states.append(state)
            if states.count > 100 { break }
        }

        #expect(states.count <= 100)
        #expect(states.last?.connection == .offline)
        #expect(states.contains { $0.connection == .offline && $0.lastFailure?.retryable == false })
    }

    @Test func retryableStreamErrorsExhaustBudgetThenGoOffline() async {
        let backend = StreamErrorBackend(streamError: .connection("dropped"))
        let conversation = AgentConversation(backend: backend, sessionID: "s", policy: exhaustPolicy)

        var states: [ConversationState] = []
        for await state in await conversation.states() {
            states.append(state)
            if states.count > 200 { break }
        }

        #expect(states.count <= 200)
        #expect(states.contains { $0.connection == .reconnecting })
        #expect(states.contains { $0.lastFailure?.retryable == true })
        #expect(states.last?.connection == .offline)
    }

    @Test func retryabilityClassificationMatchesHTTPSemantics() {
        #expect(AgentError.http(status: 400, body: "").isRetryable == false)
        #expect(AgentError.http(status: 401, body: "").isRetryable == false)
        #expect(AgentError.http(status: 403, body: "").isRetryable == false)
        #expect(AgentError.http(status: 404, body: "").isRetryable == false)
        #expect(AgentError.http(status: 408, body: "").isRetryable == true)
        #expect(AgentError.http(status: 425, body: "").isRetryable == true)
        #expect(AgentError.http(status: 429, body: "").isRetryable == true)
        #expect(AgentError.http(status: 500, body: "").isRetryable == true)
        #expect(AgentError.http(status: 503, body: "").isRetryable == true)
        #expect(AgentError.connection("drop").isRetryable == true)
        #expect(AgentError.server("boom").isRetryable == true)
        #expect(AgentError.decoding("x").isRetryable == false)
        #expect(AgentError.invalidURL("x").isRetryable == false)
        #expect(AgentError.unsupported("x").isRetryable == false)
    }

    @Test func backoffDelayGrowsMonotonicallyIsCappedAndClampsJitter() {
        let policy = ConnectionPolicy(
            reconnectBaseDelay: .milliseconds(100),
            reconnectMaxDelay: .seconds(10),
            reconnectJitter: 0.5)

        let delays = (0...20).map {
            policy.backoffDelay(attempt: $0, jitterFraction: 0).timeInterval
        }
        for index in 1..<delays.count {
            #expect(delays[index] >= delays[index - 1] - 1e-9)
        }
        #expect(delays[0] < delays[5])
        #expect(abs(delays[16] - policy.reconnectMaxDelay.timeInterval) < 1e-6)

        let base0 = policy.backoffDelay(attempt: 0, jitterFraction: 0).timeInterval
        let jit0 = policy.backoffDelay(attempt: 0, jitterFraction: 1).timeInterval
        #expect(jit0 > base0)
        #expect(abs(jit0 - 0.15) < 1e-6)

        let over = policy.backoffDelay(attempt: 0, jitterFraction: 5).timeInterval
        let under = policy.backoffDelay(attempt: 0, jitterFraction: -3).timeInterval
        #expect(abs(over - jit0) < 1e-6)
        #expect(abs(under - base0) < 1e-6)
    }

    @Test func resubscribingSupersedesTheEarlierStream() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistantEvent("a", "hi")), MockScriptStep(.status(.idle))])
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: recoveryPolicy)

        let firstStream = await conversation.states()
        let firstStreamEnded = Task {
            var count = 0
            for await _ in firstStream {
                count += 1
                if count > 500 { break }
            }
            return count <= 500
        }

        try? await Task.sleep(for: .milliseconds(20))
        let secondStream = await conversation.states()

        let endedNaturally = await firstStreamEnded.value
        #expect(endedNaturally)

        var settled: ConversationState?
        var guardCount = 0
        for await state in secondStream {
            guardCount += 1
            if state.status == .idle {
                settled = state
                break
            }
            if guardCount > 500 { break }
        }

        #expect(settled?.messages.filter { $0.role == .assistant }.count == 1)
        #expect(settled?.messages.first?.text == "hi")
    }

    @Test func liveDeltaForUnknownPartTriggersTranscriptRecovery() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [],
            replyTurns: [
                [
                    MockScriptStep(
                        .partTextDelta(messageID: "asst", partID: "asst-p", delta: "recovered"),
                        delay: .milliseconds(20))
                ]
            ],
            interactive: true)
        let conversation = AgentConversation(
            backend: backend, sessionID: "mock", policy: recoveryPolicy)

        let sender = Task {
            for _ in 0..<200 {
                if await conversation.state.hasLoadedTranscript { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            try? await Task.sleep(for: .milliseconds(30))
            try? await conversation.send("go")
        }
        defer { sender.cancel() }

        let recovered = await firstState(within: .seconds(3)) {
            for await state in await conversation.states() {
                if state.messages.contains(where: { $0.text == "recovered" }) {
                    return state
                }
            }
            return nil
        }

        #expect(recovered != nil)
        #expect(recovered?.messages.contains { $0.text == "recovered" } == true)
        #expect(recovered?.messages.contains { $0.text == "go" } == true)
    }
}
