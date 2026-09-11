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

    @Test func anUpsertWithoutAStampKeepsTheLearnedStart() {
        var reducer = MessageReducer(agentType: .openCode)
        let stamp = Date(timeIntervalSince1970: 100)
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m", role: .assistant, agentType: .openCode,
                    createdAt: Date(timeIntervalSince1970: 0)),
                replaceParts: false))
        reducer.apply(
            .partUpserted(messageID: "m", MessagePart(id: "p", kind: .text("x"), startedAt: stamp)))
        reducer.apply(
            .partUpserted(messageID: "m", MessagePart(id: "p", kind: .text("xy"))))
        #expect(reducer.snapshot.first?.parts.first?.startedAt == stamp)
        #expect(reducer.snapshot.first?.parts.first?.text == "xy")
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

@Suite("A second name for a message already held")
struct RenamedCopyTests {
    private static let answer = String(
        repeating: "These are made-up but plausible wall times for a full suite. ", count: 3)

    private func message(_ id: String, _ role: MessageRole, _ text: String, part: String = "text")
        -> ChatMessage
    {
        ChatMessage(
            id: id, role: role, agentType: .claudeCode,
            parts: [MessagePart(id: part, kind: .text(text))],
            createdAt: Date(timeIntervalSince1970: 0))
    }

    private func held() -> MessageReducer {
        var reducer = MessageReducer(agentType: .claudeCode)
        reducer.apply(.messageUpserted(message("U", .user, "make a table"), replaceParts: true))
        reducer.apply(.messageUpserted(message("A", .assistant, Self.answer), replaceParts: true))
        return reducer
    }

    @Test("The answer arriving again under the CLI's own id is the same answer")
    func renamedCopyIsFolded() {
        var reducer = held()
        reducer.apply(
            .messageUpserted(
                message("d47f42a0", .assistant, Self.answer, part: "fold-text"), replaceParts: true))
        #expect(reducer.snapshot.map(\.id) == ["U", "A"])
        #expect(reducer.snapshot[1].parts.map(\.id) == ["text"])
    }

    @Test("Parts addressed to the second name never write the words twice")
    func aliasPartsAreIgnored() {
        var reducer = held()
        reducer.apply(
            .messageUpserted(message("d47f42a0", .assistant, Self.answer), replaceParts: true))
        reducer.apply(
            .partUpserted(
                messageID: "d47f42a0", MessagePart(id: "other", kind: .text(Self.answer))))
        reducer.apply(.partTextDelta(messageID: "d47f42a0", partID: nil, delta: " again"))
        #expect(reducer.snapshot.count == 2)
        #expect(reducer.snapshot[1].text == Self.answer)
        reducer.apply(.messageRemoved(messageID: "d47f42a0"))
        #expect(reducer.snapshot.map(\.id) == ["U", "A"])
    }

    @Test("A fuller account of the same answer is taken")
    func fullerCopyReplacesParts() {
        var reducer = held()
        let longer = Self.answer + "And one more closing sentence the stream missed."
        reducer.apply(
            .messageUpserted(message("fold", .assistant, longer, part: "fold-text"), replaceParts: true))
        #expect(reducer.snapshot.map(\.id) == ["U", "A"])
        #expect(reducer.snapshot[1].text == longer)
    }

    @Test("A different answer, a short one, or one after a new prompt is its own message")
    func narrowBar() {
        var reducer = held()
        reducer.apply(
            .messageUpserted(
                message("other", .assistant, String(repeating: "A different reply entirely. ", count: 4)),
                replaceParts: true))
        #expect(reducer.snapshot.count == 3)

        var short = held()
        short.apply(.messageUpserted(message("s1", .assistant, "Done."), replaceParts: true))
        short.apply(.messageUpserted(message("s2", .assistant, "Done."), replaceParts: true))
        #expect(short.snapshot.count == 4)

        var next = held()
        next.apply(.messageUpserted(message("U2", .user, "again please"), replaceParts: true))
        next.apply(.messageUpserted(message("A2", .assistant, Self.answer), replaceParts: true))
        #expect(next.snapshot.map(\.id) == ["U", "A", "U2", "A2"])
    }
}
