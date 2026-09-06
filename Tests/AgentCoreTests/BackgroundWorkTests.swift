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

private let settled = [
    ChatMessage(
        id: "u1", role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "text", kind: .text("run the suite"))], createdAt: fixedDate),
    ChatMessage(
        id: "m1", role: .assistant, agentType: .claudeCode,
        parts: [MessagePart(id: "text", kind: .text("Started it in the background."))],
        createdAt: fixedDate),
]

/// A server whose agent process carries work between turns: the turn is closed, the transcript is
/// settled, and the machine is still running something for the conversation — which the server
/// reports on the transcript read, on its record, and as a level on the stream.
private final class CarryingServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false)

    private let lock = NSLock()
    private var carried: BackgroundWork?
    private var updatedAt = fixedDate
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?

    init(carrying work: BackgroundWork?) { carried = work }

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
    func messages(for sessionID: String) async throws -> [ChatMessage] { settled }

    func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        lock.withLock {
            TranscriptSnapshot(messages: settled, status: .idle, backgroundWork: carried)
        }
    }

    func revision(for sessionID: String) async throws -> SessionRevision? {
        lock.withLock {
            SessionRevision(updatedAt: updatedAt, running: false, backgroundWork: carried)
        }
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.attached)
        }
    }

    /// The work ends on the server while this client's stream says nothing — a phone that was
    /// suspended for the frame — so only the record can carry the news.
    func workEndsQuietly() {
        lock.withLock { carried = nil }
    }

    /// The CLI reports the change on the stream, the way it does while a client is watching.
    func report(_ work: BackgroundWork?) {
        lock.withLock { continuation }?.yield(.backgroundWork(work))
    }

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

/// Between turns a process can still be working for a conversation — a command the model started
/// and stepped back from. The turn is idle and the prompt is free, but a surface that read only
/// the status would call the conversation finished, so the work is a fact of its own on the state.
@Suite struct BackgroundWorkTests {
    private let suite = BackgroundWork(tasks: 1, task: "until grep -q DONE log; do sleep 60; done")

    @Test func workTheServerReportsOnTheReadIsOnTheState() async {
        let server = CarryingServer(carrying: suite)
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.hasLoadedTranscript }

        #expect(await conversation.state.status == .idle)
        #expect(await conversation.state.backgroundWork == suite)
        _ = states
    }

    @Test func workThatEndsWhileTheStreamIsSilentIsClearedByTheRecord() async {
        let server = CarryingServer(carrying: suite)
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { await conversation.state.backgroundWork == suite }

        server.workEndsQuietly()
        await waitUntil { await conversation.state.backgroundWork == nil }
        #expect(await conversation.state.backgroundWork == nil)
        _ = states
    }

    @Test func theStreamsOwnLevelSetsAndClearsIt() async {
        let server = CarryingServer(carrying: nil)
        let conversation = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await conversation.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await conversation.state.hasLoadedTranscript }
        #expect(await conversation.state.backgroundWork == nil)

        let two = BackgroundWork(tasks: 2)
        server.report(two)
        await waitUntil { await conversation.state.backgroundWork == two }
        #expect(await conversation.state.backgroundWork == two)
        #expect(await conversation.state.status == .idle)

        server.report(nil)
        await waitUntil { await conversation.state.backgroundWork == nil }
        #expect(await conversation.state.backgroundWork == nil)
        _ = states
    }

    @Test func aCountOfZeroIsNoWork() {
        #expect(BackgroundWork.reported(tasks: 0, task: "x") == nil)
        #expect(BackgroundWork.reported(tasks: nil, task: nil) == nil)
        #expect(BackgroundWork.reported(tasks: 3, task: nil) == BackgroundWork(tasks: 3))
    }
}
