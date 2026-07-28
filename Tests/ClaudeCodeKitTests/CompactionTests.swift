import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct CompactionDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BridgeCoding.decoder.decode(type, from: Data(json.utf8))
    }

    @Test func compactionPartCarriesTheBoundaryNumbers() throws {
        let part = try decode(
            BRPart.self,
            """
            {"kind":"compaction","compaction":{"trigger":"manual","tokensBefore":311551,
             "tokensAfter":16418,"durationMs":113822,"preservedMessages":9,"summary":"what happened"}}
            """
        ).part

        guard case .compaction(let compaction) = part.kind else {
            Issue.record("expected a compaction part")
            return
        }
        #expect(compaction.trigger == .manual)
        #expect(compaction.tokensFreed == 295_133)
        #expect(compaction.duration == 113.822)
        #expect(compaction.preservedMessageCount == 9)
        #expect(compaction.summary == "what happened")
        let reduction = try #require(compaction.reduction)
        #expect(abs(reduction - 0.947) < 0.001)
    }

    /// A boundary the bridge could only partly read still has to render — the seam matters more
    /// than the statistics beside it.
    @Test func compactionWithoutNumbersStillDecodes() throws {
        let part = try decode(BRPart.self, #"{"kind":"compaction","compaction":{}}"#).part

        guard case .compaction(let compaction) = part.kind else {
            Issue.record("expected a compaction part")
            return
        }
        #expect(compaction.trigger == nil)
        #expect(compaction.tokensFreed == nil)
        #expect(compaction.reduction == nil)
        #expect(compaction.summary == nil)
    }

    /// A bridge too old to send the part must not turn it into an empty chat bubble.
    @Test func unknownPartKindFallsBackToText() throws {
        let part = try decode(BRPart.self, #"{"kind":"nonsense","text":"hi"}"#).part
        #expect(part.kind == .text("hi"))
    }
}

@Suite struct CompactionEventTests {
    private func event(_ json: String) -> BackendEvent? {
        var decoder = BridgeEventDecoder()
        return decoder.decode(SSEvent(id: nil, type: nil, data: json))
    }

    @Test func startedAndFinishedBracketTheActivity() throws {
        guard case .compaction(let started) = event(#"{"type":"compaction","phase":"started"}"#)
        else {
            Issue.record("expected a compaction event")
            return
        }
        #expect(started?.isRunning == true)

        guard case .compaction(let finished) = event(#"{"type":"compaction","phase":"finished"}"#)
        else {
            Issue.record("expected a compaction event")
            return
        }
        #expect(finished == nil)
    }

    @Test func failureCarriesTheAgentsReason() throws {
        guard
            case .compaction(let failed) = event(
                #"{"type":"compaction","phase":"failed","error":"Not enough messages to compact."}"#)
        else {
            Issue.record("expected a compaction event")
            return
        }
        #expect(failed?.isRunning == false)
        #expect(failed?.failure == "Not enough messages to compact.")
    }
}
