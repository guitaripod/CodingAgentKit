import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private let chapterPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private let firstChapter = ConversationChapter(
    title: "Fix the stream", turn: 1, messageID: "u1", startedAt: epoch, gist: "Found the hang.",
    namedBy: .model)
private let secondChapter = ConversationChapter(
    title: "Bridge restarts", turn: 4, messageID: "u4", startedAt: epoch.addingTimeInterval(600),
    namedBy: .model)

private func waitUntil(
    _ timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// A server whose read is older than what its stream already said: the read left before the
/// second chapter opened and lands after the frame announcing it.
private final class LaggingReadServer: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false)
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation?

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(id: "s", agentType: agentType, title: "s", createdAt: epoch, updatedAt: epoch)
    }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func abort(sessionID: String) async throws {}
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws {}
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }

    func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        lock.withLock { continuation }?.yield(.chapters([firstChapter, secondChapter], revision: 2))
        try await Task.sleep(for: .milliseconds(60))
        return TranscriptSnapshot(
            messages: [], status: .idle, chapters: [firstChapter], chaptersRevision: 1)
    }

    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
            continuation.yield(.attached)
        }
    }
}

@Suite struct ChapterTests {
    @Test func theChaptersAServerKeepsAreOnTheState() async {
        let server = MockBackend(
            agentType: .claudeCode, chapters: ["mock": [firstChapter, secondChapter]])
        let chat = AgentConversation(backend: server, sessionID: "mock", policy: chapterPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }
        #expect(await chat.state.chapters == [firstChapter, secondChapter])
        _ = states
    }

    @Test func aChapterOpenedWhileWatchingArrivesWithoutARead() async {
        let server = MockBackend(agentType: .claudeCode, chapters: ["mock": [firstChapter]])
        let chat = AgentConversation(backend: server, sessionID: "mock", policy: chapterPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }
        #expect(await chat.state.chapters.count == 1)
        await waitUntil { server.subscriptionCount > 0 }
        server.setChapters([firstChapter, secondChapter], for: "mock")
        await waitUntil { await chat.state.chapters.count == 2 }
        #expect(await chat.state.chapters.last?.title == "Bridge restarts")
        _ = states
    }

    @Test func aReadOlderThanTheStreamNeverUndoesAChapter() async {
        let server = LaggingReadServer()
        let chat = AgentConversation(backend: server, sessionID: "s", policy: chapterPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await chat.state.chapters == [firstChapter, secondChapter])
        _ = states
    }

    @Test func aServerThatKeepsNoneLeavesTheStateWithout() async {
        let chat = AgentConversation(backend: MockBackend(), sessionID: "mock", policy: chapterPolicy)
        let states = await chat.states()
        await waitUntil { await chat.state.hasLoadedTranscript }
        #expect(await chat.state.chapters.isEmpty)
        _ = states
    }

    @Test func anUnknownNamerReadsAsTheModelAndATurnBelowOneAsTheFirst() throws {
        let json = #"{"title":"t","turn":0,"startedAt":"2026-11-09T15:15:02Z","namedBy":"oracle"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let chapter = try decoder.decode(ConversationChapter.self, from: Data(json.utf8))
        #expect(chapter.namedBy == .model)
        #expect(chapter.turn == 1)
        #expect(chapter.messageID == nil)
    }
}
