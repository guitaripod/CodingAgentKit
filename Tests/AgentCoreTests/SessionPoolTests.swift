import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

@Suite struct SessionPoolTests {
    /// A backend is minted for every chat, health check and quota read; minted with the same
    /// deadlines they must land in one connection pool, or every mint pays its own handshake.
    @Test func clientsWithTheSameDeadlinesShareOneSession() {
        let policy = ConnectionPolicy(requestTimeout: .seconds(17), resourceTimeout: .seconds(71))
        #expect(SessionPool.session(for: policy) === SessionPool.session(for: policy))
    }

    /// A scan's three-second budget must never be the one a transcript read inherits.
    @Test func differentDeadlinesKeepDifferentSessions() {
        let quick = ConnectionPolicy(requestTimeout: .seconds(3), resourceTimeout: .seconds(4))
        let patient = ConnectionPolicy(requestTimeout: .seconds(30), resourceTimeout: .seconds(300))
        let fast = SessionPool.session(for: quick)
        let slow = SessionPool.session(for: patient)
        #expect(fast !== slow)
        #expect(fast.configuration.timeoutIntervalForRequest == 3)
        #expect(slow.configuration.timeoutIntervalForRequest == 30)
    }
}
