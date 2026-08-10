import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private let fixedDate = Date(timeIntervalSince1970: 0)

private let userMessage = ChatMessage(
    id: "u1", role: .user, agentType: .claudeCode,
    parts: [MessagePart(id: "text", kind: .text("go"))], createdAt: fixedDate)

private let assistantShell = ChatMessage(
    id: "m1", role: .assistant, agentType: .claudeCode, parts: [], createdAt: fixedDate)

private let toolPart = MessagePart(
    id: "t1", kind: .tool(ToolCall(id: "t1", name: "bash", status: .completed, output: "ok")))

/// A turn shaped like claude-bridge's: text arrives only as deltas that name no part, a tool call
/// interrupts the first paragraph, and the answer resumes in a second one.
private let script: [BackendEvent] = [
    .messageUpserted(userMessage, replaceParts: true),
    .messageUpserted(assistantShell, replaceParts: true),
    .partTextDelta(messageID: "m1", partID: nil, delta: "Hello "),
    .partTextDelta(messageID: "m1", partID: nil, delta: "world."),
    .partUpserted(messageID: "m1", toolPart),
    .partTextDelta(messageID: "m1", partID: nil, delta: "Then "),
    .partTextDelta(messageID: "m1", partID: nil, delta: "more."),
    .status(.idle),
]

private let freezeIndex = 4

/// What a server that keeps no live copy of the turn answers a refetch made at the freeze point:
/// the first paragraph and nothing of the tool call or the paragraph after it.
private let snapshotAtFreeze: [ChatMessage] = [
    userMessage,
    ChatMessage(
        id: "m1", role: .assistant, agentType: .claudeCode,
        parts: [MessagePart(id: "text", kind: .text("Hello world."))], createdAt: fixedDate),
]

/// A server the test drives by hand: it streams exactly the events pushed into it, and answers a
/// transcript fetch with whatever snapshot has been frozen — after waiting, when held, so a refetch
/// can be made to straddle a chosen run of events.
///
/// `mirrorsLiveTurn` makes it answer the way claude-bridge does instead: the bridge folds every
/// delta it broadcasts into the partial message it keeps for the running turn and appends that
/// message to the transcript it serves, so its snapshot already contains everything the client
/// buffered while the fetch was out.
private final class ScriptedServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: false, supportsModelSelection: false, supportsAttachments: false,
        reportsMessageCompletion: false)

    private let lock = NSLock()
    private let mirrorsLiveTurn: Bool
    private var mirror: MessageReducer
    private var snapshot: [ChatMessage] = []
    private var held = false
    private var composesLate = false
    private var fetches = 0
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?

    init(mirrorsLiveTurn: Bool = false) {
        self.mirrorsLiveTurn = mirrorsLiveTurn
        self.mirror = MessageReducer(agentType: .claudeCode)
    }

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s", createdAt: fixedDate,
            updatedAt: fixedDate)
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}

    /// A fetch reports the transcript as it stood at some moment inside the window it was held for,
    /// and where in that window is exactly what the client cannot know: compose early and the
    /// buffer runs on past the answer, compose late and the answer already contains what the buffer
    /// is holding. `composesLate` picks which of the two this server is.
    func messages(for sessionID: String) async throws -> [ChatMessage] {
        let early = lock.withLock { () -> [ChatMessage] in
            fetches += 1
            return snapshot
        }
        while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(5)) }
        return lock.withLock { composesLate ? snapshot : early }
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    var isSubscribed: Bool { lock.withLock { continuation != nil } }
    var fetchCount: Int { lock.withLock { fetches } }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }
    func composeLate() { lock.withLock { composesLate = true } }
    func freeze(_ messages: [ChatMessage]) { lock.withLock { snapshot = messages } }

    func emit(_ event: BackendEvent) {
        let continuation = lock.withLock { () -> AsyncThrowingStream<BackendEvent, Error>
            .Continuation? in
            if mirrorsLiveTurn {
                mirror.apply(event)
                snapshot = mirror.snapshot
            }
            return self.continuation
        }
        continuation?.yield(event)
    }
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

/// Plays the whole script, optionally forcing a transcript refetch that is served a snapshot taken
/// while the turn is still running — the shape of a pull-to-refresh, a stale-turn nudge or a
/// recovery fetch landing in the middle of an answer.
private func drive(refetchingMidTurn: Bool, againstAMirroringServer mirroring: Bool = false) async
    -> [ChatMessage]
{
    let server = ScriptedServer(mirrorsLiveTurn: mirroring)
    if mirroring { server.composeLate() }
    let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
    let states = await conversation.states()

    await waitUntil { server.isSubscribed }
    for event in script.prefix(freezeIndex) { server.emit(event) }
    await waitUntil { await conversation.state.messages.last?.text == "Hello world." }
    if !mirroring { server.freeze(snapshotAtFreeze) }

    if refetchingMidTurn {
        server.hold()
        let fetchesBefore = server.fetchCount
        let refresh = Task { try? await conversation.refresh() }
        await waitUntil { server.fetchCount > fetchesBefore }
        for event in script.dropFirst(freezeIndex) { server.emit(event) }
        try? await Task.sleep(for: .milliseconds(100))
        server.release()
        await refresh.value
    } else {
        for event in script.dropFirst(freezeIndex) { server.emit(event) }
    }

    await waitUntil { await conversation.state.status == .idle }
    let messages = await conversation.state.messages
    _ = states
    return messages
}

/// A refetch is a suspension the event stream keeps running through, and an actor is re-entrant
/// across it: everything that streamed during the fetch used to be rebuilt away by the snapshot,
/// which is how a turn watched through a refresh lost its tool call and the whole paragraph after
/// it. The refreshed run has to end up at the same transcript as the run nobody interrupted.
@Suite struct RefreshBufferingTests {
    @Test func aRefetchMidTurnKeepsEverythingThatStreamedThroughIt() async {
        let undisturbed = await drive(refetchingMidTurn: false)
        let refetched = await drive(refetchingMidTurn: true)

        #expect(refetched.map(\.text) == undisturbed.map(\.text))
        #expect(refetched.last?.text == "Hello world.Then more.")
        #expect(refetched.last?.parts.map(\.id) == ["text", "t1", "text-1"])
        #expect(refetched == undisturbed)
    }

    /// Keeping the buffer is only half the rule. claude-bridge's own snapshot already contains
    /// every delta it broadcast before it answered, so folding the buffer onto the server's version
    /// of the message the answer is being typed into writes the same sentence twice — the reader
    /// watches the paragraph they are on repeat itself. A message the stream is writing belongs to
    /// the stream, so the refetch may not install its version of that one.
    @Test func aRefetchAgainstAServerThatMirrorsItsOwnDeltasRepeatsNothing() async {
        let undisturbed = await drive(
            refetchingMidTurn: false, againstAMirroringServer: true)
        let refetched = await drive(refetchingMidTurn: true, againstAMirroringServer: true)

        #expect(refetched.last?.text == "Hello world.Then more.")
        #expect(refetched.last?.parts.map(\.id) == ["text", "t1", "text-1"])
        #expect(refetched.map(\.text) == undisturbed.map(\.text))
        #expect(refetched == undisturbed)
    }

    /// Opening a chat on a turn already in flight is the one case the buffer cannot simply be
    /// believed: the stream is dialled before the transcript is asked for, so the deltas that
    /// arrive in between are held here AND folded into the answer the server gives. Nothing was
    /// held for those messages before the fetch, so there is no version to protect and the whole
    /// of it comes from the server — the held text has already been counted.
    @Test(arguments: [false, true])
    func openingOnALiveTurnCountsWhatArrivedDuringTheFirstFetchOnce(composingLate: Bool) async {
        let server = ScriptedServer(mirrorsLiveTurn: true)
        for event in script.prefix(freezeIndex) { server.emit(event) }

        server.hold()
        if composingLate { server.composeLate() }
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed && server.fetchCount > 0 }
        for event in script.dropFirst(freezeIndex) { server.emit(event) }
        try? await Task.sleep(for: .milliseconds(50))
        server.release()

        await waitUntil { await conversation.state.status == .idle }
        let messages = await conversation.state.messages
        #expect(messages.last?.text == "Hello world.Then more.")
        #expect(messages.last?.parts.map(\.id) == ["text", "t1", "text-1"])
        _ = states
    }

    /// A refetch answers a question about the stream that asked for it, so a reconnect must not
    /// queue behind one. It used to: the refetch chain outlived the generation, the new run loop's
    /// initial refresh waited on a request nobody cancels, and every event of the freshly dialled
    /// stream was held back until the old one timed out.
    @Test func aReconnectDoesNotQueueBehindTheRefetchItSuperseded() async {
        let server = ScriptedServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        server.hold()
        let stranded = Task { try? await conversation.refresh() }
        let fetchesBeforeReconnect = server.fetchCount
        await waitUntil { server.fetchCount > fetchesBeforeReconnect }
        let strandedFetches = server.fetchCount

        await conversation.reconnect()
        await waitUntil(.seconds(2)) { server.fetchCount > strandedFetches }
        #expect(server.fetchCount > strandedFetches)

        server.release()
        await stranded.value
        _ = states
    }

    /// A delta that names only its message addresses whatever block that message is being written
    /// into, and a message this device has never held answers nothing — the transcript diverged.
    /// Inventing a bubble to hold the text shows an answer starting mid-sentence; the refetch is
    /// what heals it.
    @Test func aDeltaForAMessageTheTranscriptNeverHeldRefetchesRatherThanInventOne() async {
        let server = ScriptedServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        let fetchesBefore = server.fetchCount
        server.emit(.partTextDelta(messageID: "ghost", partID: nil, delta: "mid-sentence"))
        await waitUntil { server.fetchCount > fetchesBefore }

        #expect(server.fetchCount > fetchesBefore)
        #expect(await conversation.state.messages.isEmpty)
        _ = states
    }
}
