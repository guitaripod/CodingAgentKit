import Foundation
import Testing

@testable import AgentCore

private let fixedDate = Date(timeIntervalSince1970: 0)

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0,
    sessionRecordInterval: .milliseconds(20)
)

private func sample(_ answer: String) -> [ChatMessage] {
    [
        ChatMessage(
            id: "u1", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "text", kind: .text("go"))], createdAt: fixedDate),
        ChatMessage(
            id: "m1", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "text", kind: .text(answer))], createdAt: fixedDate),
    ]
}

/// A server whose transport is shared and whose transcript never stamps completion — the shape of
/// claude-bridge. Events are delivered only to a live subscription and dropped otherwise, which is
/// what a shared socket does with frames published while a conversation is between subscriptions;
/// a read can be made slow; and the server can say outright whether a turn is open, both on the
/// transcript and on the session's record.
private final class SharedTransportServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false,
        reportsMessageCompletion: false)

    private let lock = NSLock()
    private var stored = sample("Hello")
    private var reportedStatus: BackendStatus?
    private var recordRunning: Bool?
    private var recordUpdatedAt: Date? = fixedDate
    private var readDelay: Duration = .zero
    private var reads = 0
    private var subscriptions = 0
    private var failFirstSubscriptionAfter: Int?
    private var delivered = 0
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?
    private var onRead: (@Sendable () -> Void)?

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s", createdAt: fixedDate,
            updatedAt: fixedDate)
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func abort(sessionID: String) async throws {}
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws {}

    func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await transcript(for: sessionID).messages
    }

    func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        let (delay, hook) = lock.withLock {
            reads += 1
            return (readDelay, onRead)
        }
        hook?()
        if delay > .zero { try await Task.sleep(for: delay) }
        return lock.withLock { TranscriptSnapshot(messages: stored, status: reportedStatus) }
    }

    func revision(for sessionID: String) async throws -> SessionRevision? {
        lock.withLock { SessionRevision(updatedAt: recordUpdatedAt, running: recordRunning) }
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let failing: Bool = lock.withLock {
                subscriptions += 1
                delivered = 0
                self.continuation = continuation
                return subscriptions == 1 && failFirstSubscriptionAfter != nil
            }
            continuation.yield(.attached)
            _ = failing
        }
    }

    /// Publishes to whoever is listening right now, and to nobody otherwise.
    func publish(_ event: BackendEvent) {
        let (target, shouldFail): (
            AsyncThrowingStream<BackendEvent, Error>.Continuation?, Bool
        ) = lock.withLock {
            delivered += 1
            let fail =
                subscriptions == 1 && failFirstSubscriptionAfter.map { delivered > $0 } == true
            return (continuation, fail)
        }
        guard let target else { return }
        if shouldFail {
            lock.withLock { continuation = nil }
            target.finish(throwing: AgentError.connection("dropped"))
            return
        }
        target.yield(event)
    }

    func store(_ answer: String, status: BackendStatus? = nil) {
        lock.withLock {
            stored = sample(answer)
            if let status { reportedStatus = status }
        }
    }

    func report(status: BackendStatus?) {
        lock.withLock { reportedStatus = status }
    }

    func record(running: Bool?, updatedAt: Date? = nil) {
        lock.withLock {
            recordRunning = running
            if let updatedAt { recordUpdatedAt = updatedAt }
        }
    }

    func setReadDelay(_ delay: Duration) {
        lock.withLock { readDelay = delay }
    }

    func failFirstSubscription(afterEvents count: Int) {
        lock.withLock { failFirstSubscriptionAfter = count }
    }

    func whenRead(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { onRead = hook }
    }

    var subscriptionCount: Int { lock.withLock { subscriptions } }
    var readCount: Int { lock.withLock { reads } }
    var isSubscribed: Bool { lock.withLock { continuation != nil } }
}

private func waitUntil(
    _ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A shared transport never ends a conversation's subscription over the socket: the socket's
/// state travels inside it as events, a lost replay is a re-read in place, and a turn end the
/// stream could not deliver is settled by the server's own word on the transcript and the record.
@Suite struct TransportContinuityTests {
    @Test func aResyncRereadsInPlaceWithoutEndingTheSubscription() async {
        let server = SharedTransportServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.messages.last?.text == "Hello" }

        server.store("Hello, world")
        server.publish(.resync)
        await waitUntil { await conversation.state.messages.last?.text == "Hello, world" }

        #expect(await conversation.state.messages.last?.text == "Hello, world")
        #expect(server.subscriptionCount == 1)
        #expect(await conversation.state.connection == .live)
        _ = states
    }

    @Test func aDetachedSocketReadsAsReconnectingUntilItAttachesAgain() async {
        let server = SharedTransportServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.connection == .live }

        server.publish(.detached)
        await waitUntil { await conversation.state.connection == .reconnecting }
        #expect(await conversation.state.connection == .reconnecting)

        server.publish(.attached)
        await waitUntil { await conversation.state.connection == .live }
        #expect(await conversation.state.connection == .live)
        #expect(server.subscriptionCount == 1)
        _ = states
    }

    @Test func theServersWordOnTheTurnSettlesARunningTheStreamLost() async {
        let server = SharedTransportServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        server.publish(.status(.running))
        await waitUntil { await conversation.state.status == .running }

        server.report(status: .idle)
        server.publish(.resync)
        await waitUntil { await conversation.state.status == .idle }
        #expect(await conversation.state.status == .idle)

        server.report(status: .running)
        server.publish(.resync)
        await waitUntil { await conversation.state.status == .running }
        #expect(await conversation.state.status == .running)
        _ = states
    }

    @Test func aTranscriptThatNeverStampsCompletionCannotEndATurnOnItsOwn() async {
        let server = SharedTransportServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        server.publish(.status(.running))
        await waitUntil { await conversation.state.status == .running }
        server.publish(.resync)
        await waitUntil { server.readCount >= 2 }
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await conversation.state.status == .running)
        _ = states
    }

    @Test func theRecordsOwnWordOnTheTurnIsFollowedInBothDirections() async {
        let server = SharedTransportServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }
        #expect(await conversation.state.status == .idle)

        server.record(running: true)
        await waitUntil { await conversation.state.status == .running }
        #expect(await conversation.state.status == .running)

        server.report(status: .idle)
        server.record(running: false)
        await waitUntil { await conversation.state.status == .idle }
        #expect(await conversation.state.status == .idle)
        _ = states
    }

    @Test func aRedialReadsTheTranscriptBesideItSoATurnEndInTheGapIsNotLost() async {
        let server = SharedTransportServer()
        server.failFirstSubscription(afterEvents: 1)
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        server.publish(.status(.running))
        await waitUntil { await conversation.state.status == .running }

        // The turn ends while the redial's own read is still out: the end is published to
        // whoever is subscribed, and a conversation that dialled first hears it, holds it, and
        // folds it on top of the read. One that read first and dialled after hears nothing.
        server.setReadDelay(.milliseconds(200))
        server.whenRead {
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                server.publish(.status(.idle))
            }
        }
        server.publish(.partTextDelta(messageID: "m1", partID: nil, delta: "!"))

        await waitUntil { await conversation.state.status == .idle }
        #expect(await conversation.state.status == .idle)
        #expect(server.subscriptionCount == 2)
        _ = states
    }
}
