import Foundation
import Testing

@testable import AgentCore

@Suite struct MessageReducerTests {
    private func assistantShell(_ id: String, completed: Date? = nil) -> ChatMessage {
        ChatMessage(
            id: id, role: .assistant, agentType: .openCode,
            createdAt: Date(timeIntervalSince1970: 0),
            completedAt: completed)
    }

    @Test func upsertAppendsInOrderAndKeepsUserText() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m1", role: .user, agentType: .openCode,
                    parts: [MessagePart(id: "p", kind: .text("hi"))],
                    createdAt: Date(timeIntervalSince1970: 0)),
                replaceParts: true))
        reducer.apply(.messageUpserted(assistantShell("m2"), replaceParts: false))

        #expect(reducer.snapshot.map(\.id) == ["m1", "m2"])
        #expect(reducer.snapshot[0].text == "hi")
    }

    @Test func partDeltaAccumulates() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(.messageUpserted(assistantShell("a"), replaceParts: false))
        reducer.apply(.partUpserted(messageID: "a", MessagePart(id: "p1", kind: .text(""))))
        reducer.apply(.partTextDelta(messageID: "a", partID: "p1", delta: "Hel"))
        reducer.apply(.partTextDelta(messageID: "a", partID: "p1", delta: "lo"))

        #expect(reducer.snapshot.first?.text == "Hello")
    }

    @Test func deltaCreatesShellAndPartWhenMissing() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(.partTextDelta(messageID: "orphan", partID: "p", delta: "x"))

        #expect(reducer.snapshot.count == 1)
        #expect(reducer.snapshot.first?.id == "orphan")
        #expect(reducer.snapshot.first?.role == .assistant)
        #expect(reducer.snapshot.first?.text == "x")
    }

    @Test func replacePartsTrueOverwritesGrowingContent() {
        var reducer = MessageReducer(agentType: .claudeCode)
        for content in ["He", "Hello", "Hello!"] {
            reducer.apply(
                .messageUpserted(
                    ChatMessage(
                        id: "m", role: .assistant, agentType: .claudeCode,
                        parts: [MessagePart(id: "content", kind: .text(content))],
                        createdAt: Date(timeIntervalSince1970: 0)),
                    replaceParts: true))
        }
        #expect(reducer.snapshot.count == 1)
        #expect(reducer.snapshot.first?.text == "Hello!")
    }

    @Test func replacePartsFalseKeepsExistingPartsAndMergesMetadata() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(.partUpserted(messageID: "m", MessagePart(id: "p1", kind: .text("keep"))))
        reducer.apply(
            .messageUpserted(
                assistantShell("m", completed: Date(timeIntervalSince1970: 5)), replaceParts: false)
        )

        #expect(reducer.snapshot.first?.text == "keep")
        #expect(reducer.snapshot.first?.completedAt != nil)
    }

    @Test func partAndMessageRemoval() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(.partUpserted(messageID: "m", MessagePart(id: "p1", kind: .text("a"))))
        reducer.apply(.partUpserted(messageID: "m", MessagePart(id: "p2", kind: .text("b"))))
        reducer.apply(.partRemoved(messageID: "m", partID: "p1"))
        #expect(reducer.snapshot.first?.parts.map(\.id) == ["p2"])

        reducer.apply(.messageRemoved(messageID: "m"))
        #expect(reducer.snapshot.isEmpty)
    }

    @Test func statusFailureUnknownDoNotAlterTranscript() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m", role: .assistant, agentType: .openCode,
                    parts: [MessagePart(id: "p", kind: .text("x"))],
                    createdAt: Date(timeIntervalSince1970: 0)),
                replaceParts: true))
        reducer.apply(.status(.running))
        reducer.apply(.failure(BackendFailure(message: "boom")))
        reducer.apply(.unknown(type: "session.status"))

        #expect(reducer.snapshot.map(\.id) == ["m"])
        #expect(reducer.snapshot.first?.text == "x")
    }

    @Test func seedInitialiserPreservesOrder() {
        let seed = [
            ChatMessage(
                id: "a", role: .user, agentType: .openCode,
                createdAt: Date(timeIntervalSince1970: 0)),
            ChatMessage(
                id: "b", role: .assistant, agentType: .openCode,
                createdAt: Date(timeIntervalSince1970: 1)),
        ]
        let reducer = MessageReducer(agentType: .openCode, messages: seed)
        #expect(reducer.snapshot.map(\.id) == ["a", "b"])
    }
}
