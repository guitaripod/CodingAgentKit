import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct ChapterDecodingTests {
    private let chapters = #"""
        [{"title":"Fix the stream","turn":1,"messageID":"u1","startedAt":"2026-11-09T13:05:00Z",
          "gist":"Found the hang.","namedBy":"model"},
         {"turn":4},
         {"title":"Bridge restarts","turn":4,"messageID":"u4","startedAt":"2026-11-09T15:15:00Z",
          "namedBy":"person"}]
        """#

    @Test func aSessionReadCarriesItsChaptersAndLeavesOutOnesItCannotRead() throws {
        let json = #"{"id":"s","title":"t","messages":[],"chaptersRevision":7,"chapters":"# + chapters + "}"
        let session = try BridgeCoding.decoder.decode(BRSession.self, from: Data(json.utf8))
        let read = session.chapters?.compactMap(\.value)
        #expect(read?.map(\.title) == ["Fix the stream", "Bridge restarts"])
        #expect(read?.first?.gist == "Found the hang.")
        #expect(read?.last?.namedBy == .person)
        #expect(session.chaptersRevision == 7)
    }

    @Test func aBridgeThatKeepsNoChaptersSaysNothing() throws {
        let session = try BridgeCoding.decoder.decode(
            BRSession.self, from: Data(#"{"id":"s","title":"t","messages":[]}"#.utf8))
        #expect(session.chapters == nil)
        #expect(session.chaptersRevision == nil)
    }

    @Test func aChaptersFrameIsTheWholeListWithItsCount() {
        var decoder = BridgeEventDecoder()
        let event = decoder.decode(
            SSEvent(id: nil, type: nil, data: #"{"type":"chapters","revision":3,"chapters":"# + chapters + "}"))
        guard case .chapters(let list, let revision)? = event else {
            Issue.record("expected chapters, got \(String(describing: event))")
            return
        }
        #expect(list.count == 2)
        #expect(revision == 3)
    }

    @Test func aClearIsAnEmptyListAndAGarbledFrameIsNothing() {
        var decoder = BridgeEventDecoder()
        guard case .chapters(let list, let revision)? = decoder.decode(
            SSEvent(id: nil, type: nil, data: #"{"type":"chapters","revision":9,"chapters":[]}"#))
        else {
            Issue.record("expected an empty list")
            return
        }
        #expect(list.isEmpty)
        #expect(revision == 9)
        #expect(decoder.decode(SSEvent(id: nil, type: nil, data: #"{"type":"chapters","chapters":"x"}"#)) == nil)
    }
}

@Suite struct BridgeMessageErrorTests {
    @Test func aFailedTurnTheBridgeKeptReadsAsAFailedAnswer() throws {
        let json = #"{"id":"a1","role":"assistant","parts":[],"createdAt":"2026-11-10T07:27:11Z","error":"HTTP 402 from https://ollama.com/api/chat"}"#
        let message = try BridgeCoding.decoder.decode(BRMessage.self, from: Data(json.utf8))
            .chat(agentType: .omp)
        #expect(message.error == "HTTP 402 from https://ollama.com/api/chat")
        let plain = try BridgeCoding.decoder.decode(
            BRMessage.self,
            from: Data(#"{"id":"a2","role":"assistant","parts":[],"createdAt":"2026-11-10T07:27:11Z","error":""}"#.utf8))
            .chat(agentType: .omp)
        #expect(plain.error == nil)
    }
}
