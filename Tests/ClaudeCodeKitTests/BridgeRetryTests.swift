import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

/// A bridge reports a turn waiting on its provider as a frame that opens the wait and one that
/// closes it; the conversation reads both as the turn's retry.
@Suite struct BridgeRetryTests {
    @Test func retryFramesOpenAndCloseTheWait() {
        var decoder = BridgeEventDecoder()
        let open = decoder.decode(
            SSEvent(
                id: nil, type: nil,
                data: #"{"type":"retry","retry":{"attempt":2,"reason":"Anthropic is rate limiting requests (429)","nextAttemptAt":"2026-11-04T00:06:00Z"}}"#))
        guard case .retry(let wait)? = open else {
            Issue.record("expected a retry, got \(String(describing: open))")
            return
        }
        #expect(wait?.attempt == 2)
        #expect(wait?.reason == "Anthropic is rate limiting requests (429)")
        let closed = decoder.decode(SSEvent(id: nil, type: nil, data: #"{"type":"retry"}"#))
        guard case .retry(let none)? = closed else {
            Issue.record("expected a closed retry, got \(String(describing: closed))")
            return
        }
        #expect(none == nil)
    }
}
