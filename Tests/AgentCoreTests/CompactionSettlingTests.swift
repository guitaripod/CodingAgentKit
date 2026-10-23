import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private func seam(_ id: String = "seam", at date: Date = Date()) -> ChatMessage {
    ChatMessage(
        id: id, role: .system, agentType: .claudeCode,
        parts: [MessagePart(id: "c", kind: .compaction(Compaction(tokensBefore: 90_000, tokensAfter: 4_000)))],
        createdAt: date, completedAt: date)
}

private func capabilities(
    asTurn: Bool = false, reportsRunning: Bool = false
) -> BackendCapabilities {
    BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: true, supportsModelSelection: true, supportsAttachments: false,
        supportsCompaction: true, compactionRunsAsTurn: asTurn,
        reportsRunningCompaction: reportsRunning, reportsMessageCompletion: false)
}

/// A conversation held open the way a client holds one, so its state can be polled.
private struct Watched {
    let conversation: AgentConversation
    let observer: Task<Void, Never>

    init(_ backend: MockBackend) {
        conversation = AgentConversation(backend: backend, sessionID: "mock", policy: fastPolicy)
        let conversation = conversation
        observer = Task { for await _ in await conversation.states() {} }
    }

    func becomes(_ predicate: @Sendable (ConversationState) -> Bool) async -> Bool {
        for _ in 0..<150 {
            if predicate(await conversation.state) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func staysTrue(for duration: Duration = .milliseconds(400), _ predicate: @Sendable (ConversationState) -> Bool) async -> Bool {
        let steps = 20
        for _ in 0..<steps {
            if !predicate(await conversation.state) { return false }
            try? await Task.sleep(for: duration / steps)
        }
        return true
    }
}

@Suite struct CompactionSettlingTests {
    @Test func aCompactionAnnouncedWhileTheTranscriptWasBeingReadIsEndedByTheSeamTheReadBringsIn() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [MockScriptStep(.compaction(CompactionActivity(startedAt: Date())), delay: .milliseconds(20))],
            interactive: true,
            capabilities: capabilities())
        backend.delayTranscript(by: .milliseconds(400))
        backend.serveInTranscriptOnly(seam(at: Date().addingTimeInterval(1)), for: "mock")
        let watched = Watched(backend)

        #expect(await watched.becomes { $0.messages.contains { $0.id == "seam" } })
        #expect(await watched.staysTrue { $0.activeCompaction == nil },
            "a seam already in the transcript read after the start left the compaction with nothing to end it")
        watched.observer.cancel()
    }

    @Test func aCompactionBegunAfterTheTailWindowOfTheLastOneShowsAgain() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
                MockScriptStep(.messageUpserted(seam(at: Date().addingTimeInterval(1)), replaceParts: true)),
                MockScriptStep(.compaction(nil)),
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date())), delay: .milliseconds(2_400)),
            ],
            interactive: true,
            capabilities: capabilities())
        let watched = Watched(backend)

        #expect(await watched.becomes { $0.messages.contains { $0.id == "seam" } })
        #expect(await watched.becomes { $0.activeCompaction != nil },
            "a compaction that began well after the last one ended was taken for its tail")
        watched.observer.cancel()
    }

    @Test func aStartTheStreamRepeatsAfterTheSeamAndTheFinishDoesNotReopenTheCompaction() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
                MockScriptStep(.messageUpserted(seam(at: Date().addingTimeInterval(1)), replaceParts: true)),
                MockScriptStep(.compaction(nil)),
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
            ],
            interactive: true,
            capabilities: capabilities())
        let watched = Watched(backend)

        #expect(await watched.becomes { $0.messages.contains { $0.id == "seam" } })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await watched.staysTrue { $0.activeCompaction == nil },
            "a progress report that outlived the finish reopened a compaction nothing would end")
        watched.observer.cancel()
    }

    @Test func aSeamThatLandedWhileTheStreamWasAwayEndsTheCompactionAtTheNextRead() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [MockScriptStep(.compaction(CompactionActivity(startedAt: Date())))],
            capabilities: capabilities(),
            transcriptPrefix: 0)
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.activeCompaction != nil })

        backend.serveInTranscriptOnly(seam(at: Date().addingTimeInterval(1)), for: "mock")
        try? await watched.conversation.refresh()

        #expect(await watched.becomes { $0.activeCompaction == nil })
        watched.observer.cancel()
    }

    @Test func aTurnThatGoesIdleEndsAClaudeCompactionTheFinishNeverClosed() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(.status(.running)),
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
                MockScriptStep(.status(.idle), delay: .milliseconds(200)),
            ],
            capabilities: capabilities(asTurn: true))
        let watched = Watched(backend)

        #expect(await watched.becomes { $0.activeCompaction != nil })
        #expect(await watched.becomes { $0.activeCompaction == nil && $0.status == .idle },
            "a turn that closed left its compaction running for good")
        watched.observer.cancel()
    }

    @Test func aSnapshotSayingTheTurnIsClosedEndsAClaudeCompaction() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [MockScriptStep(.compaction(CompactionActivity(startedAt: Date())), delay: .milliseconds(50))],
            capabilities: capabilities(asTurn: true))
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.activeCompaction != nil })

        backend.serveTranscriptStatus(.idle)
        try? await watched.conversation.refresh()

        #expect(await watched.becomes { $0.activeCompaction == nil },
            "a server reporting no turn open left a compaction on screen")
        watched.observer.cancel()
    }

    @Test func aCompactionThatIsNotATurnSurvivesAnIdleStatus() async {
        let backend = MockBackend(
            agentType: .omp,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date()))),
                MockScriptStep(.status(.idle), delay: .milliseconds(100)),
            ],
            capabilities: capabilities(asTurn: false))
        let watched = Watched(backend)

        #expect(await watched.becomes { $0.activeCompaction != nil && $0.status == .idle })
        #expect(await watched.staysTrue { $0.activeCompaction != nil },
            "an idle conversation took down the card of a compaction that runs between turns")
        watched.observer.cancel()
    }

    @Test func aBackendThatCanTellEndsACompactionItSaysIsNotRunning() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date().addingTimeInterval(-60))))
            ],
            capabilities: capabilities(reportsRunning: true))
        backend.serveRunningCompaction(CompactionActivity(startedAt: Date().addingTimeInterval(-60)))
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.activeCompaction != nil })

        backend.serveRunningCompaction(nil)
        try? await watched.conversation.refresh()

        #expect(await watched.becomes { $0.activeCompaction == nil },
            "a server that said nothing is being summarized did not end the compaction")
        watched.observer.cancel()
    }

    @Test func aBackendThatCannotTellKeepsACompactionTheStreamReported() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date().addingTimeInterval(-60))))
            ],
            capabilities: capabilities())
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.activeCompaction != nil })

        try? await watched.conversation.refresh()

        #expect(await watched.staysTrue { $0.activeCompaction != nil },
            "a nil from a backend that cannot tell took down a compaction that was running")
        watched.observer.cancel()
    }

    @Test func aRunningAnswerOlderThanTheSeamThatAnsweredItIsNotAdopted() async {
        let began = Date().addingTimeInterval(-30)
        let backend = MockBackend(
            agentType: .openCode,
            script: [],
            capabilities: capabilities(reportsRunning: true))
        backend.serveInTranscriptOnly(seam(at: began.addingTimeInterval(20)), for: "mock")
        backend.serveRunningCompaction(CompactionActivity(startedAt: began))
        let watched = Watched(backend)

        #expect(await watched.becomes { $0.hasLoadedTranscript })
        #expect(await watched.staysTrue { $0.activeCompaction == nil },
            "a stale answer started a compaction the transcript had already finished")
        watched.observer.cancel()
    }

    @Test func aCompactionNothingAnsweredForHalfAnHourIsOver() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(.compaction(CompactionActivity(startedAt: Date().addingTimeInterval(-31 * 60))))
            ],
            capabilities: capabilities(),
            transcriptPrefix: 0)
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.hasLoadedTranscript })

        try? await watched.conversation.refresh()

        #expect(await watched.becomes { $0.activeCompaction == nil },
            "a compaction older than any summarize can be stayed on screen")
        watched.observer.cancel()
    }
}
