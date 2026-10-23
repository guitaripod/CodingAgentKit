import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let fixedDate = Date(timeIntervalSince1970: 0)

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0,
    sessionRecordInterval: .seconds(60)
)

private func item(_ id: String, _ text: String = "go") -> QueuedPrompt {
    QueuedPrompt(id: id, text: text, createdAt: fixedDate)
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

/// Holds a read of the transcript until the test lets it go, so the stream can be heard while the
/// read is out.
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// A server that keeps the queue, idempotent on the prompt's id, with its stream and its answers
/// told by hand so a test can put the stream and a read in either order.
private final class QueueServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false,
        supportsAbort: true, supportsServerQueue: true, supportsQueueEdit: true)

    private let lock = NSLock()
    private var served = QueueSnapshot()
    private var readQueue: QueueSnapshot?
    private var running = false
    private var gate: Gate?
    private var readsStarted = 0
    private var failuresOwed = 0
    private var delay: Duration = .zero
    private var newerOnStream: QueueSnapshot?
    private var calls: [EnqueuePrompt] = []
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s", createdAt: fixedDate,
            updatedAt: fixedDate)
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws {}
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }

    var enqueueCalls: [EnqueuePrompt] { lock.withLock { calls } }
    var heldQueue: QueueSnapshot { lock.withLock { served } }
    var readsBegun: Int { lock.withLock { readsStarted } }
    var isSubscribed: Bool { lock.withLock { continuation != nil } }

    func hold(_ snapshot: QueueSnapshot) { lock.withLock { served = snapshot } }
    func serveOnRead(_ snapshot: QueueSnapshot?) { lock.withLock { readQueue = snapshot } }
    func setRunning(_ value: Bool) { lock.withLock { running = value } }
    func holdReads(behind gate: Gate?) { lock.withLock { self.gate = gate } }
    func failEnqueues(_ count: Int) { lock.withLock { failuresOwed = count } }
    func delayEnqueues(by value: Duration) { lock.withLock { delay = value } }
    func announceOnEnqueue(_ snapshot: QueueSnapshot?) { lock.withLock { newerOnStream = snapshot } }

    func announce(_ snapshot: QueueSnapshot) {
        lock.withLock { continuation }?.yield(.queue(snapshot))
    }

    func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        let (gate, snapshot, status) = lock.withLock {
            readsStarted += 1
            return (self.gate, readQueue ?? served, running)
        }
        if let gate { await gate.wait() }
        return TranscriptSnapshot(
            messages: [], status: status ? .running : .idle, queue: snapshot)
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.attached)
        }
    }

    func enqueue(sessionID: String, prompt: EnqueuePrompt) async throws -> EnqueueResult {
        let (pause, fails) = lock.withLock {
            calls.append(prompt)
            let fails = failuresOwed > 0
            if fails { failuresOwed -= 1 }
            return (delay, fails)
        }
        if pause > .zero { try await Task.sleep(for: pause) }
        if fails { throw AgentError.connection("the answer was lost") }
        let (result, newer) = lock.withLock { () -> (EnqueueResult, QueueSnapshot?) in
            if !running, served.items.isEmpty {
                return (EnqueueResult(started: true, queue: served), nil)
            }
            if !served.items.contains(where: { $0.id == prompt.id }) {
                served.items.append(item(prompt.id, prompt.prompt.text))
            }
            return (EnqueueResult(started: false, queue: served), newerOnStream)
        }
        if let newer { announce(newer) }
        return result
    }

    func cancelQueued(sessionID: String, id: String) async throws -> QueueSnapshot {
        try lock.withLock {
            guard served.items.contains(where: { $0.id == id }) else { return served }
            served.items.removeAll { $0.id == id }
            return served
        }
    }

    func editQueued(sessionID: String, id: String, edit: QueuedPromptEdit) async throws
        -> QueueSnapshot
    {
        try lock.withLock {
            guard let index = served.items.firstIndex(where: { $0.id == id }) else {
                throw QueueError.alreadyStarted
            }
            if let text = edit.text { served.items[index].text = text }
            return served
        }
    }
}

@Suite struct SharedQueueFoldingTests {
    @Test func aQueueTheStreamAnnouncesIsOnTheState() async {
        let server = QueueServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await conversation.state.hasLoadedTranscript }

        server.announce(QueueSnapshot(items: [item("a"), item("b")], paused: true))
        await waitUntil { await conversation.state.queue.count == 2 }

        let state = await conversation.state
        #expect(state.queue.map(\.id) == ["a", "b"])
        #expect(state.queuePaused)
        _ = states
    }

    @Test func aReadOutranksAnEventOlderThanIt() async throws {
        let server = QueueServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript && server.isSubscribed }

        server.announce(QueueSnapshot(items: [item("old")]))
        await waitUntil { await conversation.state.queue.map(\.id) == ["old"] }
        server.hold(QueueSnapshot(items: [item("fresh")]))
        try await conversation.refresh()

        #expect(await conversation.state.queue.map(\.id) == ["fresh"])
        _ = states
    }

    @Test func anEventNewerThanTheReadStandsOverIt() async throws {
        let server = QueueServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript && server.isSubscribed }

        let gate = Gate()
        server.holdReads(behind: gate)
        server.serveOnRead(QueueSnapshot(items: [item("read")]))
        let before = server.readsBegun
        let refreshing = Task { try await conversation.refresh() }
        await waitUntil { server.readsBegun > before }

        server.announce(QueueSnapshot(items: [item("event")]))
        try await Task.sleep(for: .milliseconds(40))
        await gate.release()
        try await refreshing.value

        #expect(await conversation.state.queue.map(\.id) == ["event"])
        _ = states
    }

    @Test func aServerThatSaysNothingAboutTheQueueLeavesItAlone() async throws {
        let backend = MockBackend(agentType: .openCode, interactive: true)
        let conversation = AgentConversation(backend: backend, sessionID: "mock", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        let state = await conversation.state
        #expect(state.queue.isEmpty)
        #expect(!state.queuePaused)
        #expect(!backend.capabilities.supportsServerQueue)
        _ = states
    }

    @Test func aStateCachedBeforeTheQueueExistedStillDecodes() throws {
        var state = ConversationState(status: .idle, hasLoadedTranscript: true)
        state.queue = [item("a")]
        state.queuePaused = true
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object["queue"] = nil
        object["queuePaused"] = nil

        let old = try JSONDecoder().decode(
            ConversationState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.queue.isEmpty)
        #expect(!old.queuePaused)
        #expect(old.status == .idle)

        let round = try JSONDecoder().decode(
            ConversationState.self, from: JSONEncoder().encode(state))
        #expect(round == state)
    }

    @Test func aQueuedPromptWithAKindItDoesNotKnowReadsAsAPrompt() throws {
        let json = #"{"id":"a","text":"go","kind":"macro","createdAt":0}"#
        let decoded = try JSONDecoder().decode(QueuedPrompt.self, from: Data(json.utf8))
        #expect(decoded.kind == .prompt)
        #expect(decoded.attachments.isEmpty)
    }
}

@Suite struct SharedQueueEnqueueTests {
    private func conversation(_ backend: any CodingAgentBackend) -> AgentConversation {
        AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)
    }

    @Test func anEnqueueBehindARunningTurnJoinsTheQueue() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.running)
        let conversation = conversation(backend)

        let result = try await conversation.enqueue("after this", id: "a")

        #expect(!result.started)
        #expect(result.queue.items.map(\.id) == ["a"])
        let state = await conversation.state
        #expect(state.queue.map(\.text) == ["after this"])
        #expect(backend.recordedPrompts.isEmpty)
    }

    @Test func anEnqueueWithNothingRunningStartsAtOnceAndNeverQueues() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.idle)
        let conversation = conversation(backend)

        let result = try await conversation.enqueue("now", id: "a")

        #expect(result.started)
        let state = await conversation.state
        #expect(state.queue.isEmpty)
        #expect(state.status == .running)
        #expect(backend.recordedPrompts.map(\.text) == ["now"])
    }

    @Test func repeatingAnIdIsAnsweredWithoutASecondRequest() async throws {
        let server = QueueServer()
        server.setRunning(true)
        let conversation = conversation(server)

        let first = try await conversation.enqueue("once", id: "a")
        let again = try await conversation.enqueue("once", id: "a")

        #expect(server.enqueueCalls.count == 1)
        #expect(first.started == again.started)
        #expect(again.queue.items.map(\.id) == ["a"])
    }

    @Test func anEnqueueWhoseAnswerWasLostIsRetriedUnderTheSameId() async throws {
        let server = QueueServer()
        server.setRunning(true)
        server.failEnqueues(1)
        let conversation = conversation(server)

        await #expect(throws: AgentError.self) {
            try await conversation.enqueue("once", id: "a")
        }
        let result = try await conversation.enqueue("once", id: "a")

        #expect(server.enqueueCalls.map(\.id) == ["a", "a"])
        #expect(result.queue.items.map(\.id) == ["a"])
        #expect(server.heldQueue.items.count == 1)
        #expect(await conversation.state.queue.map(\.id) == ["a"])
    }

    @Test func callsWithOneIdAtTheSameTimeShareOneRequest() async throws {
        let server = QueueServer()
        server.setRunning(true)
        server.delayEnqueues(by: .milliseconds(80))
        let conversation = conversation(server)

        async let first = conversation.enqueue("twice", id: "a")
        async let second = conversation.enqueue("twice", id: "a")
        let results = try await [first, second]

        #expect(server.enqueueCalls.count == 1)
        #expect(results.map(\.queue.items.count) == [1, 1])
    }

    @Test func aQueueTheStreamAnnouncedWhileTheRequestWasOutStandsOverItsAnswer() async throws {
        let server = QueueServer()
        server.setRunning(true)
        let conversation = conversation(server)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript && server.isSubscribed }
        server.announceOnEnqueue(QueueSnapshot(items: [item("a"), item("later")]))

        _ = try await conversation.enqueue("hello", id: "a")
        await waitUntil { await conversation.state.queue.count == 2 }

        #expect(await conversation.state.queue.map(\.id) == ["a", "later"])
        _ = states
    }

    @Test func aBackendWithoutAServerQueueRefusesAnEnqueue() async {
        let backend = MockBackend()
        let conversation = conversation(backend)

        await #expect(throws: AgentError.unsupported("queue")) {
            try await conversation.enqueue("hello")
        }
        #expect(await conversation.state.queue.isEmpty)
    }
}

@Suite struct SharedQueueEditingTests {
    private func conversation(_ backend: any CodingAgentBackend) -> AgentConversation {
        AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)
    }

    @Test func editingAQueuedPromptChangesItsText() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.running)
        let conversation = conversation(backend)
        try await conversation.enqueue("draft", id: "a")

        try await conversation.editQueued(id: "a", text: "final")

        #expect(await conversation.state.queue.map(\.text) == ["final"])
        #expect(backend.servedQueue(for: "s").items.map(\.text) == ["final"])
        #expect(backend.recordedQueueEdits == ["a"])
    }

    @Test func cancellingTakesThePromptOutOfTheQueue() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.running)
        let conversation = conversation(backend)
        try await conversation.enqueue("one", id: "a")
        try await conversation.enqueue("two", id: "b")

        try await conversation.cancelQueued(id: "a")

        #expect(await conversation.state.queue.map(\.id) == ["b"])
        #expect(backend.recordedQueueCancels == ["a"])
    }

    @Test func cancellingAnIdThatIsGoneIsNotAnError() async throws {
        let backend = MockBackend(serverQueue: true)
        let conversation = conversation(backend)

        try await conversation.cancelQueued(id: "never-was")
        try await conversation.cancelQueued(id: "never-was")

        #expect(await conversation.state.queue.isEmpty)
    }

    @Test func aPromptThatStartedRefusesAnEditAndIsDroppedFromTheQueueHeld() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.running)
        let conversation = conversation(backend)
        try await conversation.enqueue("one", id: "a")
        await backend.startQueued(id: "a", in: "s")

        await #expect(throws: QueueError.alreadyStarted) {
            try await conversation.editQueued(id: "a", text: "too late")
        }
        #expect(await conversation.state.queue.isEmpty)
    }

    @Test func aPromptThatStartedRefusesACancel() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.running)
        let conversation = conversation(backend)
        try await conversation.enqueue("one", id: "a")
        await backend.startQueued(id: "a", in: "s")

        await #expect(throws: QueueError.alreadyStarted) {
            try await conversation.cancelQueued(id: "a")
        }
        #expect(await conversation.state.queue.isEmpty)
    }

    @Test func theRefusalIsSomethingAPersonCanBeShown() {
        let message = QueueError.alreadyStarted.errorDescription
        #expect(message?.isEmpty == false)
    }

    @Test func aStopHoldsTheQueueBackAndResumingStartsIt() async throws {
        let backend = MockBackend(interactive: true, serverQueue: true)
        backend.serveTranscriptStatus(.running)
        backend.serveQueue(QueueSnapshot(items: [item("a", "next up")]), for: "s")
        let conversation = conversation(backend)
        let states = await conversation.states()
        await waitUntil { await conversation.state.queue.map(\.id) == ["a"] }

        try await conversation.cancelCurrentTurn()
        await waitUntil { await conversation.state.queuePaused }
        #expect(await conversation.state.queuePaused)
        #expect(await conversation.state.queue.map(\.id) == ["a"])

        backend.serveTranscriptStatus(.idle)
        try await conversation.resumeQueue()
        await waitUntil { await conversation.state.queue.isEmpty }

        let state = await conversation.state
        #expect(!state.queuePaused)
        #expect(state.queue.isEmpty)
        #expect(backend.recordedPrompts.map(\.text) == ["next up"])
        #expect(backend.recordedQueueResumes == 1)
        _ = states
    }

    @Test func enqueueingAfterAStopLiftsThePause() async throws {
        let backend = MockBackend(serverQueue: true)
        backend.serveTranscriptStatus(.running)
        backend.serveQueue(QueueSnapshot(items: [item("a")], paused: true), for: "s")
        let conversation = conversation(backend)

        try await conversation.enqueue("more", id: "b")

        let state = await conversation.state
        #expect(!state.queuePaused)
        #expect(state.queue.map(\.id) == ["a", "b"])
    }
}
