import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private func message(_ id: String, _ text: String, at offset: TimeInterval) -> ChatMessage {
    let at = Date(timeIntervalSince1970: 1_800_000_000 + offset)
    return ChatMessage(
        id: id, role: id.hasPrefix("u") ? .user : .assistant, agentType: .openCode,
        parts: [MessagePart(id: "t", kind: .text(text))], createdAt: at, completedAt: at)
}

private func held(_ ids: [String]) -> [MockScriptStep] {
    ids.enumerated().map { index, id in
        MockScriptStep(.messageUpserted(message(id, "held \(id)", at: Double(index)), replaceParts: true))
    }
}

private struct Watched {
    let conversation: AgentConversation
    let observer: Task<Void, Never>

    init(_ backend: MockBackend) {
        conversation = AgentConversation(backend: backend, sessionID: "mock", policy: fastPolicy)
        let conversation = conversation
        observer = Task { for await _ in await conversation.states() {} }
    }

    func becomes(
        within polls: Int = 150, _ predicate: @Sendable (ConversationState) -> Bool
    ) async -> Bool {
        for _ in 0..<polls {
            if predicate(await conversation.state) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite struct RecentTailTests {
    @Test func theEndOfAHeldConversationShowsBeforeTheWholeOfItHasBeenRead() async {
        let backend = MockBackend(
            agentType: .openCode, script: held(["u1", "a1", "u2", "a2"]), interactive: false)
        backend.serveRecentTranscript(true)
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.messages.count == 4 })

        backend.serveInTranscriptOnly(message("u3", "while away", at: 10), for: "mock")
        backend.serveInTranscriptOnly(message("a3", "the latest result", at: 11), for: "mock")
        backend.delayTranscript(by: .milliseconds(700))
        await watched.conversation.reconnect()

        #expect(
            await watched.becomes(within: 30) { $0.messages.map(\.id) == ["u1", "a1", "u2", "a2", "u3", "a3"] },
            "the latest result waited for the whole transcript")
        #expect(backend.recentTranscriptReads >= 1)
        watched.observer.cancel()
    }

    @Test func aServerThatCannotReadTheEndShowsItWithTheWholeConversation() async {
        let backend = MockBackend(
            agentType: .openCode, script: held(["u1", "a1"]), interactive: false)
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.messages.count == 2 })

        backend.serveInTranscriptOnly(message("a2", "the latest result", at: 11), for: "mock")
        backend.delayTranscript(by: .milliseconds(300))
        await watched.conversation.reconnect()

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await watched.conversation.state.messages.count == 2)
        #expect(await watched.becomes(within: 400) { $0.messages.count == 3 })
        #expect(backend.recentTranscriptReads == 0)
        watched.observer.cancel()
    }

    @Test func aTailThatDoesNotMeetWhatIsHeldIsLeftToTheFullRead() async {
        let backend = MockBackend(
            agentType: .openCode, script: held(["u1", "a1"]), interactive: false)
        backend.serveRecentTranscript(true)
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.messages.count == 2 })

        for index in 0..<40 {
            backend.serveInTranscriptOnly(
                message("n\(index)", "new \(index)", at: Double(10 + index)), for: "mock")
        }
        backend.delayTranscript(by: .milliseconds(300))
        await watched.conversation.reconnect()

        try? await Task.sleep(for: .milliseconds(150))
        #expect(await watched.conversation.state.messages.count == 2)
        #expect(await watched.becomes(within: 400) { $0.messages.count == 42 })
        watched.observer.cancel()
    }

    @Test func theFullReadStillSettlesWhatTheTailLeftOut() async {
        let backend = MockBackend(
            agentType: .openCode, script: held(["u1", "a1"]), interactive: false)
        backend.serveRecentTranscript(true)
        let watched = Watched(backend)
        #expect(await watched.becomes { $0.messages.count == 2 })

        backend.serveInTranscriptOnly(message("a2", "the latest result", at: 11), for: "mock")
        backend.delayTranscript(by: .milliseconds(300))
        await watched.conversation.reconnect()

        #expect(await watched.becomes(within: 400) { $0.messages.map(\.id) == ["u1", "a1", "a2"] })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await watched.conversation.state.messages.map(\.id) == ["u1", "a1", "a2"])
        watched.observer.cancel()
    }

    @Test func aTailIsSplicedAfterWhatIsHeldBeforeItsFirstMessage() {
        let heldMessages = ["u1", "a1", "u2", "a2"].map { message($0, "held \($0)", at: 0) }
        let tail = [message("u2", "held u2", at: 0), message("a2", "grown a2", at: 0), message("u3", "new", at: 1)]
        let joined = AgentConversation.splice(tail, onto: heldMessages)
        #expect(joined?.map(\.id) == ["u1", "a1", "u2", "a2", "u3"])
        #expect(joined?[3].text == "grown a2")
    }

    @Test func aTailThatBeginsOnAMessageNotHeldIsNotSpliced() {
        let heldMessages = ["u1", "a1"].map { message($0, "held \($0)", at: 0) }
        #expect(AgentConversation.splice([message("x", "new", at: 1)], onto: heldMessages) == nil)
        #expect(AgentConversation.splice([], onto: heldMessages) == nil)
    }
}
