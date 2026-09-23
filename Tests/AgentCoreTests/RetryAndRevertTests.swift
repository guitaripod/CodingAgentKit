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

private func prompt(_ id: String, _ text: String) -> ChatMessage {
    ChatMessage(
        id: id, role: .user, agentType: .openCode,
        parts: [MessagePart(id: "\(id)/text", kind: .text(text))], createdAt: fixedDate,
        completedAt: fixedDate)
}

private func answer(_ id: String, _ text: String) -> ChatMessage {
    ChatMessage(
        id: id, role: .assistant, agentType: .openCode,
        parts: [MessagePart(id: "\(id)/text", kind: .text(text))], createdAt: fixedDate,
        completedAt: fixedDate)
}

private let conversation = [
    prompt("msg_01", "first"), answer("msg_02", "one"),
    prompt("msg_03", "second"), answer("msg_04", "two"),
]

/// A server that keeps a revert on its record and answers the stream by hand, so a revert, its
/// undoing and a provider wait can each be told to a conversation exactly as a server tells them.
private final class RevertingServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .openCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false,
        supportsAbort: true, supportsRevert: true)

    private let lock = NSLock()
    private var standing: SessionRevert?
    private var busyRefusals: Int
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?
    private(set) var aborts = 0
    private(set) var revertCalls = 0

    init(refusingBusy: Int = 0) { busyRefusals = refusingBusy }

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s", createdAt: fixedDate,
            updatedAt: fixedDate)
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws {}
    func messages(for sessionID: String) async throws -> [ChatMessage] { conversation }

    func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        lock.withLock { TranscriptSnapshot(messages: conversation, status: .idle, revert: standing) }
    }

    func abort(sessionID: String) async throws {
        lock.withLock { aborts += 1 }
    }

    func revert(sessionID: String, to messageID: String) async throws -> SessionRevert {
        try lock.withLock {
            revertCalls += 1
            if busyRefusals > 0 {
                busyRefusals -= 1
                throw AgentError.http(status: 409, body: #"{"_tag":"SessionBusyError"}"#)
            }
            let revert = SessionRevert(
                messageID: messageID,
                files: [SessionRevert.File(path: "a.swift", change: .modified, additions: 2)])
            standing = revert
            return revert
        }
    }

    func restoreRevert(sessionID: String) async throws {
        lock.withLock { standing = nil }
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.attached)
        }
    }

    func say(_ event: BackendEvent) {
        lock.withLock { continuation }?.yield(event)
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

@Suite struct RevertTests {
    @Test func aStandingRevertSetsAsideItsBoundaryAndEverythingAfter() async throws {
        let server = RevertingServer()
        let chat = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }

        try await chat.revert(to: "msg_03")
        let reverted = await chat.state
        #expect(reverted.messages.map(\.id) == ["msg_01", "msg_02"])
        #expect(reverted.revertedMessages.map(\.id) == ["msg_03", "msg_04"])
        #expect(reverted.revert?.files.first?.path == "a.swift")

        try await chat.restoreRevert()
        let restored = await chat.state
        #expect(restored.messages.map(\.id) == ["msg_01", "msg_02", "msg_03", "msg_04"])
        #expect(restored.revertedMessages.isEmpty)
        #expect(restored.revert == nil)
        _ = states
    }

    @Test func aRevertTheServerHoldsComesBackWithTheTranscript() async throws {
        let server = RevertingServer()
        _ = try await server.revert(sessionID: "s", to: "msg_03")
        let chat = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }
        #expect(await chat.state.messages.map(\.id) == ["msg_01", "msg_02"])
        #expect(await chat.state.revert?.messageID == "msg_03")
        _ = states
    }

    @Test func aBusyServerIsStoppedAndAskedAgainRatherThanRefusingThePress() async throws {
        let server = RevertingServer(refusingBusy: 2)
        let chat = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }

        try await chat.revert(to: "msg_03")
        #expect(server.revertCalls == 3)
        #expect(server.aborts == 1)
        #expect(await chat.state.revert?.messageID == "msg_03")
        _ = states
    }

    @Test func aBoundaryTheTranscriptDoesNotDrawCutsAtTheFirstMessageAfterIt() {
        let revert = SessionRevert(messageID: "msg_025")
        #expect(AgentConversation.revertBoundary(of: revert, in: conversation) == 2)
        let foreign = [prompt("u1", "x"), answer("a1", "y")]
        #expect(AgentConversation.revertBoundary(of: SessionRevert(messageID: "msg_9"), in: foreign) == nil)
    }

    @Test func theStreamStagesAndClearsARevert() async {
        let server = RevertingServer()
        let chat = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await chat.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await chat.state.hasLoadedTranscript }

        server.say(.revert(SessionRevert(messageID: "msg_03")))
        await waitUntil { await chat.state.revert != nil }
        #expect(await chat.state.messages.count == 2)
        server.say(.revert(nil))
        await waitUntil { await chat.state.revert == nil }
        #expect(await chat.state.messages.count == 4)
        _ = states
    }
}

@Suite struct ProviderRetryTests {
    private let wait = TurnRetry(
        attempt: 2, reason: "Rate limit reached", nextAttemptAt: Date(timeIntervalSince1970: 60))

    @Test func aWaitRunsTheTurnAndEndsWhenAnAttemptAnswers() async {
        let server = RevertingServer()
        let chat = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await chat.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await chat.state.hasLoadedTranscript }

        server.say(.retry(wait))
        await waitUntil { await chat.state.retry != nil }
        #expect(await chat.state.retry == wait)
        #expect(await chat.state.status == .running)

        server.say(.partTextDelta(messageID: "msg_04", partID: "msg_04/text", delta: " more"))
        await waitUntil { await chat.state.retry == nil }
        #expect(await chat.state.retry == nil)
        #expect(await chat.state.status == .running)
        _ = states
    }

    @Test func aWaitEndsWithTheTurnOrItsFailure() async {
        let server = RevertingServer()
        let chat = AgentConversation(backend: server, sessionID: "s", policy: fastPolicy)
        let states = await chat.states()
        await waitUntil { server.isSubscribed }
        await waitUntil { await chat.state.hasLoadedTranscript }

        server.say(.retry(wait))
        await waitUntil { await chat.state.retry != nil }
        server.say(.status(.idle))
        await waitUntil { await chat.state.retry == nil }
        #expect(await chat.state.retry == nil)

        server.say(.retry(wait))
        await waitUntil { await chat.state.retry != nil }
        server.say(.failure(BackendFailure(message: "gave up")))
        await waitUntil { await chat.state.retry == nil }
        #expect(await chat.state.retry == nil)
        #expect(await chat.state.lastFailure?.message == "gave up")
        _ = states
    }
}

@Suite struct TranscriptNoteCodingTests {
    @Test func everyNoteSurvivesACachedTranscript() throws {
        let subjects: [TranscriptNote.Subject] = [
            .model(
                ModelSelection(providerID: "p", modelID: "m"), effort: "high",
                previous: ModelSelection(providerID: "q", modelID: "n")),
            .agent("plan", previous: nil),
            .resumedAfterRestart,
            .workFinished("cargo test", work: .command, outcome: .failed),
            .instructions("Loaded AGENTS.md"),
            .moved("/w"),
            .skill("review"),
            .remark("anything"),
        ]
        for subject in subjects {
            let part = MessagePart(id: "n", kind: .note(TranscriptNote(subject)))
            let data = try JSONEncoder().encode(part)
            #expect(try JSONDecoder().decode(MessagePart.self, from: data) == part)
        }
        let message = ChatMessage(
            id: "n", role: .system, agentType: .openCode,
            parts: [MessagePart(id: "n", kind: .note(TranscriptNote(.resumedAfterRestart)))],
            createdAt: fixedDate, completedAt: fixedDate)
        #expect(!message.carriesAnswer)
    }
}
