import Testing

@testable import ClaudeCodeKit

@Suite struct BridgeResumeTests {
    @Test func theFirstDialHasNothingToReplay() {
        #expect(BridgeStream.resume(hasCursor: false, silence: 9_999) == .fresh)
    }

    @Test func aBlipIsBridgedFrameForFrame() {
        #expect(BridgeStream.resume(hasCursor: true, silence: 3) == .replay)
        #expect(BridgeStream.resume(hasCursor: true, silence: BridgeStream.replayHorizon) == .replay)
    }

    @Test func aPhoneBackFromItsPocketJoinsAtTheHeadInsteadOfReplayingTheRing() {
        #expect(BridgeStream.resume(hasCursor: true, silence: BridgeStream.replayHorizon + 1) == .snapshot)
        #expect(BridgeStream.resume(hasCursor: true, silence: 6 * 3600) == .snapshot)
    }
}
