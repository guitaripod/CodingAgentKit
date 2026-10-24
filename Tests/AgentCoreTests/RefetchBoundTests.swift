import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private func answer(_ id: String, _ text: String) -> ChatMessage {
    ChatMessage(
        id: id, role: .assistant, agentType: .claudeCode,
        parts: [MessagePart(id: "text", kind: .text(text))],
        createdAt: Date(timeIntervalSince1970: 0))
}

private func eventually(
    timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// A door a test holds shut to keep a read in flight for exactly as long as the test wants, so an
/// order of events is decided by the test and not by how fast the machine runs.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in released { waiter.resume() }
    }
}

/// A server that answers every transcript read after a delay and keeps count of how many reads
/// were out at once and in what order they began.
private final class CountingServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: false, supportsModelSelection: false, supportsAttachments: false,
        reportsMessageCompletion: false)

    private let lock = NSLock()
    private let delay: Duration
    private let hold: Latch?
    private var inFlight = 0
    private var peak = 0
    private var started: [String] = []
    private var content: [ChatMessage]

    init(delay: Duration = .milliseconds(40), hold: Latch? = nil, content: [ChatMessage] = []) {
        self.delay = delay
        self.hold = hold
        self.content = content
    }

    var peakInFlight: Int { lock.withLock { peak } }
    var startedOrder: [String] { lock.withLock { started } }
    var readCount: Int { lock.withLock { started.count } }
    func serve(_ messages: [ChatMessage]) { lock.withLock { content = messages } }

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        throw AgentError.unsupported("create")
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}

    func messages(for sessionID: String) async throws -> [ChatMessage] {
        let served = lock.withLock { () -> [ChatMessage] in
            started.append(sessionID)
            inFlight += 1
            peak = max(peak, inFlight)
            return content
        }
        defer { lock.withLock { inFlight -= 1 } }
        if let hold { await hold.wait() }
        try await Task.sleep(for: delay)
        return served
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

private actor CountingCache: SessionCache {
    private(set) var stored: [[ChatMessage]] = []
    private(set) var readsStarted = 0
    private(set) var readsReturned = 0
    private let seed: [ChatMessage]
    private let hold: Latch?

    init(seed: [ChatMessage] = [], hold: Latch? = nil) {
        self.seed = seed
        self.hold = hold
    }

    func sessions(for agentType: AgentType) async -> [AgentSession] { [] }
    func store(_ sessions: [AgentSession], for agentType: AgentType) async {}
    func messages(for sessionID: String) async -> [ChatMessage] {
        readsStarted += 1
        if let hold { await hold.wait() }
        readsReturned += 1
        return seed
    }
    func store(_ messages: [ChatMessage], for sessionID: String) async {
        stored.append(messages)
    }
}

@Suite struct RefreshGateTests {
    @Test func admitsUpToTheLimitAndHandsTheNextTurnToTheHighestPriority() async throws {
        let gate = RefreshGate(limit: 1)
        let held = try await gate.acquire(priority: RefreshPriorityBox())
        let order = OrderLog()
        let low = RefreshPriorityBox()
        low.priority = .background
        let mid = RefreshPriorityBox()
        let high = RefreshPriorityBox()
        high.priority = .foreground
        var tasks: [Task<Void, Never>] = []
        for (name, box) in [("low", low), ("mid", mid), ("high", high), ("mid2", RefreshPriorityBox())]
        {
            tasks.append(
                Task {
                    let permit = try? await gate.acquire(priority: box)
                    await order.append(name)
                    permit?.release()
                })
            let expected = tasks.count
            #expect(await eventually { gate.waitingCount == expected })
        }
        held.release()
        for task in tasks { await task.value }

        #expect(await order.names == ["high", "mid", "mid2", "low"])
        #expect(gate.runningCount == 0)
    }

    @Test func aWaiterThatIsCancelledLeavesTheQueueAndHoldsNothing() async throws {
        let gate = RefreshGate(limit: 1)
        let held = try await gate.acquire(priority: RefreshPriorityBox())
        let waiting = Task { _ = try await gate.acquire(priority: RefreshPriorityBox()) }
        #expect(await eventually { gate.waitingCount == 1 })
        waiting.cancel()
        let outcome = await waiting.result

        #expect(throws: CancellationError.self) { try outcome.get() }
        #expect(gate.waitingCount == 0)
        held.release()
        #expect(gate.runningCount == 0)
    }

    @Test func aTurnThatLapsesGoesToTheNextWaiterAndIsNotGivenBackTwice() async throws {
        let gate = RefreshGate(limit: 1, lease: .milliseconds(200))
        let stalled = try await gate.acquire(priority: RefreshPriorityBox())
        let next = try await gate.acquire(priority: RefreshPriorityBox())

        #expect(gate.runningCount == 1)
        stalled.release()
        #expect(gate.runningCount == 1)
        next.release()
        next.release()
        #expect(gate.runningCount == 0)
    }

    @Test func aTaskCancelledBeforeItAsksIsNeverQueued() async throws {
        let gate = RefreshGate(limit: 1)
        let held = try await gate.acquire(priority: RefreshPriorityBox())
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return (try? await gate.acquire(priority: RefreshPriorityBox())) == nil
        }
        task.cancel()

        #expect(await task.value)
        #expect(gate.waitingCount == 0)
        held.release()
    }

    private actor OrderLog {
        var names: [String] = []
        func append(_ name: String) { names.append(name) }
    }
}

@Suite struct ConversationRefetchBoundTests {
    @Test func aProcessReadsFewTranscriptsAtOnceHoweverManyAskTogether() async throws {
        let gate = RefreshGate(limit: 2)
        let server = CountingServer(content: [answer("a", "hello")])
        var conversations: [AgentConversation] = []
        for index in 0..<6 {
            let conversation = AgentConversation(
                backend: server, sessionID: "s\(index)", policy: fastPolicy)
            await conversation.useRefreshGate(gate)
            conversations.append(conversation)
        }
        var streams: [AsyncStream<ConversationState>] = []
        for conversation in conversations { streams.append(await conversation.states()) }

        let all = conversations
        #expect(
            await eventually {
                var loaded = 0
                for conversation in all where await conversation.state.hasLoadedTranscript {
                    loaded += 1
                }
                return loaded == 6
            })
        #expect(server.peakInFlight == 2)
        #expect(server.readCount == 6)
        #expect(gate.runningCount == 0)
        _ = streams
    }

    @Test func theConversationOnScreenIsReadBeforeTheOnesBehindIt() async throws {
        let gate = RefreshGate(limit: 1)
        let gateTurn = try await gate.acquire(priority: RefreshPriorityBox())
        let server = CountingServer(delay: .milliseconds(10), content: [answer("a", "hello")])
        let priorities: [(String, RefreshPriority)] = [
            ("early", .normal), ("behind", .background), ("shown", .foreground),
        ]
        var held: [AgentConversation] = []
        var streams: [AsyncStream<ConversationState>] = []
        for (id, priority) in priorities {
            let conversation = AgentConversation(backend: server, sessionID: id, policy: fastPolicy)
            await conversation.useRefreshGate(gate)
            await conversation.setRefreshPriority(priority)
            streams.append(await conversation.states())
            held.append(conversation)
            let expected = held.count
            #expect(await eventually { gate.waitingCount == expected })
        }
        gateTurn.release()

        #expect(await eventually { server.readCount == 3 })
        #expect(server.startedOrder == ["shown", "early", "behind"])
        _ = streams
    }

    @Test func aConversationBroughtToTheFrontMovesUpWhileItsReadIsWaiting() async throws {
        let gate = RefreshGate(limit: 1)
        let gateTurn = try await gate.acquire(priority: RefreshPriorityBox())
        let server = CountingServer(delay: .milliseconds(10), content: [answer("a", "hello")])
        var held: [AgentConversation] = []
        var streams: [AsyncStream<ConversationState>] = []
        for id in ["one", "two", "three"] {
            let conversation = AgentConversation(backend: server, sessionID: id, policy: fastPolicy)
            await conversation.useRefreshGate(gate)
            streams.append(await conversation.states())
            held.append(conversation)
            let expected = held.count
            #expect(await eventually { gate.waitingCount == expected })
        }
        await held[2].setRefreshPriority(.foreground)
        gateTurn.release()

        #expect(await eventually { server.readCount == 3 })
        #expect(server.startedOrder.first == "three")
        _ = streams
    }

    @Test func refetchesAskedForWhileOneIsWaitingAreOneRead() async throws {
        let gate = RefreshGate(limit: 1)
        let held = try await gate.acquire(priority: RefreshPriorityBox())
        let server = CountingServer(delay: .milliseconds(10), content: [answer("a", "hello")])
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        await conversation.useRefreshGate(gate)
        let stream = await conversation.states()
        #expect(await eventually { gate.waitingCount == 1 })

        async let first: Void = conversation.refresh()
        async let second: Void = conversation.refresh()
        async let third: Void = conversation.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        held.release()
        try await first
        try await second
        try await third

        #expect(await eventually { await conversation.state.hasLoadedTranscript })
        #expect(server.readCount == 1)
        _ = stream
    }

    @Test func aRefetchAskedForAfterTheReadWentOutGetsItsOwn() async throws {
        let server = CountingServer(delay: .milliseconds(200), content: [answer("a", "hello")])
        let conversation = AgentConversation(
            backend: server, sessionID: "s", policy: fastPolicy)
        await conversation.useRefreshGate(RefreshGate(limit: 2))
        let stream = await conversation.states()
        #expect(await eventually { server.readCount == 1 })

        let later = Task { try await conversation.refresh() }
        try await later.value

        #expect(server.readCount == 2)
        _ = stream
    }

    @Test func abandoningTheOnlyWaiterOfAQueuedReadCancelsIt() async throws {
        let gate = RefreshGate(limit: 1)
        let held = try await gate.acquire(priority: RefreshPriorityBox())
        let server = CountingServer(content: [answer("a", "hello")])
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        await conversation.useRefreshGate(gate)

        let asking = Task { try await conversation.refresh() }
        #expect(await eventually { gate.waitingCount == 1 })
        asking.cancel()
        _ = await asking.result

        #expect(await eventually { gate.waitingCount == 0 })
        #expect(server.readCount == 0)
        held.release()
        #expect(gate.runningCount == 0)
    }
}

@Suite struct ConversationPersistTests {
    @Test func aRefetchThatFoundNothingNewWritesNothing() async throws {
        let cache = CountingCache()
        let server = CountingServer(delay: .milliseconds(5), content: [answer("a", "hello")])
        let conversation = AgentConversation(
            backend: server, sessionID: "s", policy: fastPolicy, cache: cache)
        let stream = await conversation.states()
        #expect(await eventually { await cache.stored.count == 1 })

        for _ in 0..<3 { try await conversation.refresh() }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(await cache.stored.count == 1)
        _ = stream
    }

    @Test func aRefetchThatFoundSomethingNewWritesOnce() async throws {
        let cache = CountingCache()
        let server = CountingServer(delay: .milliseconds(5), content: [answer("a", "hello")])
        let conversation = AgentConversation(
            backend: server, sessionID: "s", policy: fastPolicy, cache: cache)
        let stream = await conversation.states()
        #expect(await eventually { await cache.stored.count == 1 })

        server.serve([answer("a", "hello"), answer("b", "and more")])
        try await conversation.refresh()
        try await conversation.refresh()

        #expect(await eventually { await cache.stored.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        let stored = await cache.stored
        #expect(stored.count == 2)
        #expect(stored.last?.map(\.id) == ["a", "b"])
        _ = stream
    }
}

@Suite struct ConversationSeedTests {
    @Test func aCacheThatIsSlowToReadDoesNotDelayTheLiveRead() async throws {
        let stale = [answer("old", "from the cache")]
        let cacheRead = Latch()
        let cache = CountingCache(seed: stale, hold: cacheRead)
        let server = CountingServer(delay: .milliseconds(5), content: [answer("new", "from the server")])
        let conversation = AgentConversation(
            backend: server, sessionID: "s", policy: fastPolicy, cache: cache)
        let stream = await conversation.states()

        #expect(await eventually { await cache.readsStarted == 1 })
        #expect(await eventually { await conversation.messages.first?.id == "new" })
        #expect(await cache.readsReturned == 0)

        cacheRead.open()
        #expect(await eventually { await cache.readsReturned == 1 })
        for _ in 0..<20 { await Task.yield() }
        #expect(await conversation.messages.map(\.id) == ["new"])
        _ = stream
    }

    @Test func aCacheThatIsFastPaintsBeforeTheServerAnswers() async throws {
        let cache = CountingCache(seed: [answer("old", "from the cache")])
        let serverRead = Latch()
        let server = CountingServer(
            delay: .milliseconds(5), hold: serverRead, content: [answer("new", "from the server")])
        let conversation = AgentConversation(
            backend: server, sessionID: "s", policy: fastPolicy, cache: cache)
        let stream = await conversation.states()

        #expect(await eventually { server.readCount == 1 })
        #expect(await eventually { await conversation.messages.first?.id == "old" })

        serverRead.open()
        #expect(await eventually { await conversation.messages.first?.id == "new" })
        _ = stream
    }

    @Test func aCacheNeverOverwritesAServerThatSaidTheConversationIsEmpty() async throws {
        let cacheRead = Latch()
        let cache = CountingCache(seed: [answer("old", "from the cache")], hold: cacheRead)
        let server = CountingServer(delay: .milliseconds(5), content: [])
        let conversation = AgentConversation(
            backend: server, sessionID: "s", policy: fastPolicy, cache: cache)
        let stream = await conversation.states()
        #expect(await eventually { await conversation.state.hasLoadedTranscript })

        cacheRead.open()
        #expect(await eventually { await cache.readsReturned == 1 })
        for _ in 0..<20 { await Task.yield() }

        #expect(await conversation.messages.isEmpty)
        _ = stream
    }
}
