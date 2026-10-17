import Foundation
import Testing

@testable import AgentCore

/// The renaming test as it was written before it was made cheap, kept as the oracle the cheap one
/// has to agree with on every transcript.
private enum LegacyRename {
    static let renameEvidence = 80

    static func words(of message: ChatMessage) -> String {
        message.parts.reduce(into: "") { text, part in
            if case .text(let value) = part.kind { text += value }
        }
    }

    static func renamedCopy(of message: ChatMessage, in messages: [ChatMessage]) -> Int? {
        guard message.role == .assistant else { return nil }
        let incoming = words(of: message)
        guard incoming.count >= renameEvidence else { return nil }
        let prompt = messages.lastIndex { $0.role == .user } ?? -1
        guard
            let index = messages.indices.reversed().first(where: {
                $0 > prompt && messages[$0].role == .assistant && !words(of: messages[$0]).isEmpty
            })
        else { return nil }
        let held = words(of: messages[index])
        guard min(held.count, incoming.count) >= renameEvidence,
            held.hasPrefix(incoming) || incoming.hasPrefix(held)
        else { return nil }
        return index
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct ReducerRenameEquivalenceTests {
    private static let pieces = [
        "the build failed on the linker step", "and then we tried again ", "é", "e\u{301}",
        "🇫🇮", "👨‍👩‍👧", "x", "", " ", "alpha beta gamma delta epsilon zeta eta theta iota kappa ",
        "a longer sentence that goes on for a while so that two answers can share an opening ",
    ]

    private static func text(_ rng: inout SeededGenerator, shared: String?) -> String {
        var value = shared ?? ""
        for _ in 0..<Int.random(in: 0...6, using: &rng) {
            value += pieces.randomElement(using: &rng)!
        }
        return value
    }

    private static func message(
        _ id: Int, _ rng: inout SeededGenerator, opening: String?
    ) -> ChatMessage {
        let role: MessageRole = [.user, .assistant, .assistant, .assistant, .system]
            .randomElement(using: &rng)!
        var parts: [MessagePart] = []
        for index in 0..<Int.random(in: 0...3, using: &rng) {
            let kind: MessagePart.Kind
            switch Int.random(in: 0...4, using: &rng) {
            case 0: kind = .reasoning(text(&rng, shared: nil))
            case 1: kind = .tool(ToolCall(id: "t\(id)-\(index)", name: "bash", status: .completed))
            default:
                kind = .text(text(&rng, shared: index == 0 ? opening : nil))
            }
            parts.append(MessagePart(id: "p\(index)", kind: kind))
        }
        return ChatMessage(
            id: "m\(id)", role: role, agentType: .claudeCode, parts: parts,
            createdAt: Date(timeIntervalSince1970: Double(id)))
    }

    private static func secondAccount(
        of messages: [ChatMessage], id: Int, _ rng: inout SeededGenerator
    ) -> ChatMessage? {
        guard let held = messages.last(where: { $0.role == .assistant }) else { return nil }
        let words = LegacyRename.words(of: held)
        let kept: String
        switch Int.random(in: 0...2, using: &rng) {
        case 0: kept = words
        case 1: kept = String(words.prefix(Int.random(in: 70...120, using: &rng)))
        default: kept = words + text(&rng, shared: nil)
        }
        return ChatMessage(
            id: "copy\(id)", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "text", kind: .text(kept))],
            createdAt: Date(timeIntervalSince1970: Double(id)))
    }

    @Test func cheapRenameTestAgreesWithTheOriginalOnRandomTranscripts() {
        var rng = SeededGenerator(state: 20_261_017)
        var renamed = 0
        var decided = 0
        for round in 0..<400 {
            var reducer = MessageReducer(agentType: .claudeCode)
            var opening: String?
            for step in 0..<Int.random(in: 1...14, using: &rng) {
                if Int.random(in: 0...3, using: &rng) == 0 {
                    opening = Self.text(&rng, shared: nil) + Self.pieces.last! + Self.pieces[9]
                }
                var incoming = Self.message(round * 100 + step, &rng, opening: opening)
                if Int.random(in: 0...2, using: &rng) == 0 {
                    incoming = Self.secondAccount(of: reducer.snapshot, id: round * 100 + step, &rng)
                        ?? incoming
                }
                let expected = LegacyRename.renamedCopy(of: incoming, in: reducer.snapshot)
                let actual = reducer.renamedCopy(of: incoming)
                #expect(actual == expected, "round \(round) step \(step)")
                decided += 1
                if expected != nil { renamed += 1 }
                reducer.apply(.messageUpserted(incoming, replaceParts: true))
            }
        }
        #expect(decided > 1_000)
        #expect(renamed > 20, "the generator never produced a second account of an answer")
    }

    @Test func aBulkRebuildHoldsTheSameMessagesAsApplyingThemOneByOne() {
        var rng = SeededGenerator(state: 99)
        for round in 0..<100 {
            var opening: String?
            var messages: [ChatMessage] = []
            for step in 0..<Int.random(in: 1...30, using: &rng) {
                if Int.random(in: 0...3, using: &rng) == 0 {
                    opening = Self.text(&rng, shared: nil) + Self.pieces.last! + Self.pieces[9]
                }
                messages.append(Self.message(round * 100 + step, &rng, opening: opening))
            }
            var oneByOne = MessageReducer(agentType: .claudeCode)
            for message in messages {
                oneByOne.apply(.messageUpserted(message, replaceParts: true))
            }
            let bulk = MessageReducer(agentType: .claudeCode, messages: messages)
            #expect(bulk.snapshot == oneByOne.snapshot)
        }
    }

    @Test func graphemeBoundIsExactAtTheEvidenceLength() {
        for length in [78, 79, 80, 81] {
            let plain = String(repeating: "a", count: length)
            let combining = String(repeating: "e\u{301}", count: length)
            let flags = String(repeating: "🇫🇮", count: length)
            for text in [plain, combining, flags] {
                let reached = text.index(text.startIndex, offsetBy: 80, limitedBy: text.endIndex)
                #expect((reached != nil) == (text.count >= 80))
            }
        }
    }

    @Test func revisionMovesOnEveryEventThatCanChangeTheTranscript() {
        var reducer = MessageReducer(agentType: .claudeCode)
        let start = reducer.revision
        reducer.apply(.status(.running))
        #expect(reducer.revision == start)
        reducer.apply(.partTextDelta(messageID: "a", partID: "p", delta: "x"))
        #expect(reducer.revision == start + 1)
        reducer.apply(.messageRemoved(messageID: "a"))
        #expect(reducer.revision == start + 2)
    }
}
