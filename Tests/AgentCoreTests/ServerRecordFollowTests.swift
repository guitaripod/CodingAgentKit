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

private func transcript(_ answer: String, completed: Bool = false) -> [ChatMessage] {
    [
        ChatMessage(
            id: "u1", role: .user, agentType: .openCode,
            parts: [MessagePart(id: "text", kind: .text("go"))], createdAt: fixedDate),
        ChatMessage(
            id: "m1", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "text", kind: .text(answer))], createdAt: fixedDate,
            completedAt: completed ? fixedDate : nil,
            isStreaming: !completed),
    ]
}

/// A server whose turns are run by another process on its machine: the transcript in its storage
/// grows and its session record moves with it, while the event stream this client is holding stays
/// open and says nothing at all — which is exactly what opencode's per-process bus does to a
/// session started by `opencode run`, a second serve, or a CLI left working in a terminal.
private final class OutOfProcessServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .openCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false)

    private let lock = NSLock()
    private let reportsRecord: Bool
    private var stored: [ChatMessage]
    private var updatedAt: Date
    private var fetches = 0
    private var records = 0
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?

    init(reportsRecord: Bool = true) {
        self.reportsRecord = reportsRecord
        self.stored = transcript("Hello")
        self.updatedAt = fixedDate
    }

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
        lock.withLock {
            fetches += 1
            return stored
        }
    }

    func revision(for sessionID: String) async throws -> SessionRevision? {
        lock.withLock {
            records += 1
            return reportsRecord ? SessionRevision(updatedAt: updatedAt) : nil
        }
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.attached)
        }
    }

    /// One turn's worth of work by the other process: the words land in storage and the record
    /// moves. Nothing is emitted, because nothing would be.
    func writeFromAnotherProcess(_ answer: String, at seconds: TimeInterval, completed: Bool = false)
    {
        lock.withLock {
            stored = transcript(answer, completed: completed)
            updatedAt = Date(timeIntervalSince1970: seconds)
        }
    }

    var isSubscribed: Bool { lock.withLock { continuation != nil } }
    var fetchCount: Int { lock.withLock { fetches } }
    var recordCount: Int { lock.withLock { records } }
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

/// A silent stream is not evidence that nothing happened. A conversation therefore follows the
/// server's own record of the session, and re-reads the transcript whenever that record moves —
/// which is the only thing that can see a turn this connection was never told about.
@Suite struct ServerRecordFollowTests {
    @Test func aTurnRunByAnotherProcessIsRenderedWithoutLeavingTheChat() async {
        let server = OutOfProcessServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await conversation.state.messages.last?.text == "Hello" }

        server.writeFromAnotherProcess("Hello, world", at: 10)
        await waitUntil { await conversation.state.messages.last?.text == "Hello, world" }
        #expect(await conversation.state.messages.last?.text == "Hello, world")

        server.writeFromAnotherProcess("Hello, world. Done.", at: 20, completed: true)
        await waitUntil { await conversation.state.messages.last?.text == "Hello, world. Done." }
        #expect(await conversation.state.messages.last?.text == "Hello, world. Done.")
        _ = states
    }

    /// A turn nobody streamed is still a turn in flight: the refetch it triggers reads an assistant
    /// message the server has not finished, and the conversation must say so, or the chat renders a
    /// growing answer with nothing anywhere admitting that work is happening.
    @Test func aTurnNobodyStreamedStillReadsAsRunning() async {
        let server = OutOfProcessServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await conversation.state.messages.last?.text == "Hello" }

        server.writeFromAnotherProcess("Hello, world", at: 10)
        await waitUntil { await conversation.state.messages.last?.text == "Hello, world" }
        #expect(await conversation.state.status == .running)

        server.writeFromAnotherProcess("Hello, world. Done.", at: 20, completed: true)
        await waitUntil { await conversation.state.status == .idle }
        #expect(await conversation.state.status == .idle)
        _ = states
    }

    /// The record is consulted, not obeyed on a clock: a session nothing has written to costs one
    /// small request per interval and never a transcript fetch, so watching an idle chat is not a
    /// poll of the whole conversation.
    @Test func aRecordThatHasNotMovedRefetchesNothing() async {
        let server = OutOfProcessServer()
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await conversation.state.messages.last?.text == "Hello" }
        let fetchesAfterOpening = server.fetchCount

        await waitUntil(.milliseconds(300)) { false }

        #expect(server.recordCount > 1)
        #expect(server.fetchCount == fetchesAfterOpening)
        _ = states
    }

    /// A backend that cannot answer leaves the question unanswered. Nothing is inferred from a nil
    /// — no refetch, no claim that the conversation is current — and the conversation keeps running
    /// on its other defences.
    @Test func aServerThatCannotSayIsNeverTakenToMeanNothingChanged() async {
        let server = OutOfProcessServer(reportsRecord: false)
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await conversation.state.messages.last?.text == "Hello" }
        let fetchesAfterOpening = server.fetchCount

        server.writeFromAnotherProcess("Hello, world", at: 10)
        await waitUntil(.milliseconds(300)) { false }

        #expect(server.fetchCount == fetchesAfterOpening)
        #expect(await conversation.state.messages.last?.text == "Hello")
        _ = states
    }
}
