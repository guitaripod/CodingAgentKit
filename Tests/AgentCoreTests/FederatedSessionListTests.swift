import AgentCore
import Foundation
import Testing

private struct StubBackend: CodingAgentBackend {
    let agentType: AgentType = .openCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: false, supportsAttachments: false)
    var sessions: [AgentSession] = []
    var failure: (any Error)?
    var delay: Duration?

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }

    func listSessions() async throws -> [AgentSession] {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        return sessions
    }

    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        throw AgentError.unsupported("stub")
    }
    func deleteSession(_ sessionID: String) async throws {}
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func abort(sessionID: String) async throws {}
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws {}
    func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {}
    func rejectQuestion(_ request: QuestionRequest) async throws {}
    func availableModels() async throws -> [ModelInfo] { [] }
    func defaultModel() async throws -> ModelSelection? { nil }
}

private func session(_ id: String, _ updated: Date, active: Bool = false) -> AgentSession {
    AgentSession(
        id: id, agentType: .openCode, title: id, createdAt: updated, updatedAt: updated,
        isActive: active)
}

@Suite struct FederatedSessionListTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test func mergesHostsNewestFirstAndStampsOrigin() async throws {
        let list = FederatedSessionList(deadline: .seconds(5))
        await list.setHosts([
            ("arch", StubBackend(sessions: [session("a", epoch)])),
            ("macbook", StubBackend(sessions: [session("b", epoch.addingTimeInterval(60))])),
        ])
        var final: FederatedSnapshot?
        for await snapshot in await list.refresh() { final = snapshot }
        let snapshot = try #require(final)
        #expect(snapshot.isComplete)
        #expect(snapshot.sessions.map(\.id) == ["b", "a"])
        #expect(snapshot.sessions.map(\.hostID) == ["macbook", "arch"])
        #expect(snapshot.sessions[0].ref?.storageKey == "macbook/b")
    }

    @Test func sameSessionIDOnTwoHostsStaysDistinct() async throws {
        let list = FederatedSessionList(deadline: .seconds(5))
        await list.setHosts([
            ("arch", StubBackend(sessions: [session("ses_1", epoch)])),
            ("macbook", StubBackend(sessions: [session("ses_1", epoch.addingTimeInterval(1))])),
        ])
        var final: FederatedSnapshot?
        for await snapshot in await list.refresh() { final = snapshot }
        let keys = try #require(final).sessions.compactMap { $0.ref?.storageKey }
        #expect(Set(keys) == ["arch/ses_1", "macbook/ses_1"])
    }

    @Test func aSleepingHostCannotStallTheInbox() async throws {
        let list = FederatedSessionList(deadline: .milliseconds(80))
        await list.setHosts([
            ("arch", StubBackend(sessions: [session("a", epoch)])),
            ("asleep", StubBackend(sessions: [], delay: .seconds(30))),
        ])
        let started = ContinuousClock().now
        var final: FederatedSnapshot?
        for await snapshot in await list.refresh() { final = snapshot }
        let elapsed = ContinuousClock().now - started
        #expect(elapsed < .seconds(2))
        let snapshot = try #require(final)
        #expect(!snapshot.isComplete)
        #expect(snapshot.sessions.map(\.id) == ["a"])
        #expect(snapshot.staleHosts.map(\.hostID) == ["asleep"])
    }

    @Test func aFailedHostKeepsItsLastKnownRowsButGoesStale() async throws {
        let clock = ClockBox(epoch)
        let list = FederatedSessionList(deadline: .seconds(5), now: clock.read)
        await list.setHosts([("macbook", StubBackend(sessions: [session("a", epoch, active: true)]))])
        for await _ in await list.refresh() {}
        let live = await list.currentSnapshot()
        #expect(live.isComplete)

        await list.setHosts([
            ("macbook", StubBackend(sessions: [], failure: AgentError.unsupported("asleep")))
        ])
        for await _ in await list.refresh() {}
        let stale = await list.currentSnapshot()
        #expect(!stale.isComplete)
        #expect(stale.sessions.map(\.id) == ["a"])
    }

    @Test func aStaleHostFreezesElapsedInsteadOfTicking() async throws {
        let clock = ClockBox(epoch)
        let list = FederatedSessionList(deadline: .seconds(5), now: clock.read)
        await list.setHosts([("macbook", StubBackend(sessions: [session("a", epoch, active: true)]))])
        for await _ in await list.refresh() {}

        await list.setHosts([
            ("macbook", StubBackend(sessions: [], failure: AgentError.unsupported("asleep")))
        ])
        for await _ in await list.refresh() {}

        let snapshot = await list.currentSnapshot()
        let running = try #require(snapshot.sessions.first)
        let muchLater = epoch.addingTimeInterval(4 * 3600)
        #expect(snapshot.elapsedReference(for: running, now: muchLater) == epoch)
    }

    @Test func aLiveHostMeasuresElapsedAgainstNow() async throws {
        let clock = ClockBox(epoch)
        let list = FederatedSessionList(deadline: .seconds(5), now: clock.read)
        await list.setHosts([("arch", StubBackend(sessions: [session("a", epoch, active: true)]))])
        for await _ in await list.refresh() {}
        let snapshot = await list.currentSnapshot()
        let running = try #require(snapshot.sessions.first)
        let later = epoch.addingTimeInterval(90)
        #expect(snapshot.elapsedReference(for: running, now: later) == later)
    }

    @Test func cachedSnapshotRendersBeforeAnyHostAnswersAndNeverTicks() async throws {
        let cache = InMemorySessionCache()
        var stored = session("a", epoch, active: true)
        stored.hostID = "macbook"
        await cache.store([stored], forHost: "macbook")

        let list = FederatedSessionList(cache: cache, deadline: .milliseconds(50))
        await list.setHosts([("macbook", StubBackend(sessions: [], delay: .seconds(30)))])
        let first = await list.cachedSnapshot()
        #expect(first.sessions.map(\.id) == ["a"])
        #expect(!first.isComplete)
        let later = epoch.addingTimeInterval(3600)
        #expect(first.elapsedReference(for: try #require(first.sessions.first), now: later) == later)
    }

    @Test func refreshEmitsCachedRowsBeforeTheSlowHostResolves() async throws {
        let list = FederatedSessionList(deadline: .milliseconds(80))
        await list.setHosts([
            ("arch", StubBackend(sessions: [session("a", epoch)])),
            ("asleep", StubBackend(sessions: [], delay: .seconds(30))),
        ])
        var counts: [Int] = []
        for await snapshot in await list.refresh() { counts.append(snapshot.sessions.count) }
        #expect(counts.first == 0)
        #expect(counts.contains(1))
    }

    @Test func sessionRefRoundTripsThroughItsStorageKey() {
        let ref = SessionRef(hostID: "macbook", sessionID: "ses_1/2")
        let restored = SessionRef(storageKey: ref.storageKey)
        #expect(restored == ref)
        #expect(SessionRef(storageKey: "nohost") == nil)
        #expect(SessionRef(storageKey: "/only") == nil)
    }
}

private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var read: @Sendable () -> Date { { self.lock.withLock { self.value } } }
    func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
}
