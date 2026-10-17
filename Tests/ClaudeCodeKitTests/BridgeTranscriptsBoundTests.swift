import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct BridgeTranscriptsBoundTests {
    private static let empty = TranscriptSnapshot(messages: [])
    private static let megabyte = 1_048_576

    @Test func holdsAtMostTheCountWhateverTheirSize() {
        let held = BridgeTranscripts()
        for index in 0..<(BridgeTranscripts.capacity + 5) {
            held.hold("s\(index)", etag: "e", snapshot: Self.empty, bytes: 1)
        }

        #expect(held.heldIDs.count == BridgeTranscripts.capacity)
        #expect(held.held("s0") == nil)
        #expect(held.held("s\(BridgeTranscripts.capacity + 4)") != nil)
    }

    @Test func dropsTheOldestCopiesWhenTheBytesGoOverBudget() {
        let held = BridgeTranscripts()
        let size = BridgeTranscripts.byteBudget / 3
        for index in 0..<5 {
            held.hold("s\(index)", etag: "e", snapshot: Self.empty, bytes: size)
        }

        #expect(held.heldIDs == ["s2", "s3", "s4"])
        #expect(held.totalBytes == 3 * size)
    }

    @Test func theCopyReadLastIsKeptEvenWhenItAloneIsOverBudget() {
        let held = BridgeTranscripts()
        held.hold("small", etag: "e", snapshot: Self.empty, bytes: Self.megabyte)
        held.hold("huge", etag: "e", snapshot: Self.empty, bytes: BridgeTranscripts.byteBudget * 2)

        #expect(held.heldIDs == ["huge"])
        #expect(held.held("huge")?.etag == "e")
        #expect(held.totalBytes == BridgeTranscripts.byteBudget * 2)
    }

    @Test func replacingAndForgettingKeepTheByteCountExact() {
        let held = BridgeTranscripts()
        held.hold("a", etag: "e", snapshot: Self.empty, bytes: 100)
        held.hold("b", etag: "e", snapshot: Self.empty, bytes: 50)
        held.hold("a", etag: "e2", snapshot: Self.empty, bytes: 30)
        #expect(held.totalBytes == 80)
        #expect(held.held("a")?.etag == "e2")

        held.hold("b", etag: nil, snapshot: Self.empty, bytes: 999)
        #expect(held.totalBytes == 30)
        held.forget("a")
        #expect(held.totalBytes == 0)
        #expect(held.heldIDs.isEmpty)
    }
}
