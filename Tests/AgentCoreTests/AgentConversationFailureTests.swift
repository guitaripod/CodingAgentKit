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

/// A backend whose first subscription dies with a terminal error and whose later ones stream
/// normally — the shape of a server that rejected one dial and then came back, which is what
/// exposes a conversation left permanently dead by its own finished run loop.
private final class RecoveringStreamBackend: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .openCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: false, supportsModelSelection: false, supportsAttachments: false)
    private let lock = NSLock()
    private var attempts = 0

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        lock.lock()
        attempts += 1
        let attempt = attempts
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if attempt == 1 {
                continuation.finish(throwing: AgentError.http(status: 401, body: ""))
            } else {
                continuation.yield(assistantEvent("a", "hi"))
                continuation.yield(.status(.idle))
            }
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

    @Test func aNewObserverAfterATerminalFailureDialsAgain() async {
        let backend = RecoveringStreamBackend()
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: terminalPolicy)

        for await state in await conversation.states() {
            if state.connection == .offline { break }
        }

        let settled = await firstState(within: .seconds(5)) {
            for await state in await conversation.states() {
                if state.status == .idle, state.messages.first?.text == "hi" { return state }
            }
            return nil
        }

        #expect(settled != nil)
        #expect(settled?.messages.first?.text == "hi")
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

    @Test func everyObserverSeesTheSameConversation() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistantEvent("a", "hi")), MockScriptStep(.status(.idle))])
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: recoveryPolicy)

        let firstStream = await conversation.states()
        let secondStream = await conversation.states()

        async let first = settledState(of: firstStream)
        async let second = settledState(of: secondStream)
        let (a, b) = await (first, second)

        #expect(a?.messages.filter { $0.role == .assistant }.count == 1)
        #expect(a?.messages.first?.text == "hi")
        #expect(b?.messages.map(\.id) == a?.messages.map(\.id))
        #expect(b?.messages.first?.text == "hi")
    }

    @Test func lettingOneObserverGoLeavesTheOtherRunning() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistantEvent("a", "hi")), MockScriptStep(.status(.idle))])
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: recoveryPolicy)

        let survivor = await conversation.states()
        do {
            let transient = await conversation.states()
            var iterator = transient.makeAsyncIterator()
            _ = await iterator.next()
        }
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await conversation.hasObservers)

        let settled = await settledState(of: survivor)
        #expect(settled?.messages.first?.text == "hi")
    }

    @Test func anApprovalAnsweredElsewhereStopsAsking() async {
        let request = PermissionRequest(id: "p1", sessionID: "s", title: "Run tests", toolName: "bash")
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(.permission(request)),
                MockScriptStep(.permissionResolved(requestID: "p1"), delay: .milliseconds(200)),
                MockScriptStep(.permission(request)),
                MockScriptStep(.status(.idle)),
            ])
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: recoveryPolicy)

        var sawTheRequest = false
        var settled: ConversationState?
        var seen = 0
        for await state in await conversation.states() {
            seen += 1
            if !state.pendingPermissions.isEmpty { sawTheRequest = true }
            if sawTheRequest, state.status == .idle, state.pendingPermissions.isEmpty {
                settled = state
                break
            }
            if seen > 500 { break }
        }

        #expect(sawTheRequest)
        #expect(settled?.pendingPermissions.isEmpty == true)
    }

    @Test func reconnectingKeepsEveryObserver() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(assistantEvent("a", "hi")), MockScriptStep(.status(.idle))])
        let conversation = AgentConversation(
            backend: backend, sessionID: "s", policy: recoveryPolicy)

        let stream = await conversation.states()
        await conversation.reconnect()
        #expect(await conversation.hasObservers)

        let settled = await settledState(of: stream)
        #expect(settled?.messages.first?.text == "hi")
    }

    private func settledState(of stream: AsyncStream<ConversationState>) async
        -> ConversationState?
    {
        var seen = 0
        for await state in stream {
            seen += 1
            if state.status == .idle { return state }
            if seen > 500 { return nil }
        }
        return nil
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
