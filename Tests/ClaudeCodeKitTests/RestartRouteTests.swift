import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// `restartServer()` asks `/restart` first, because that route restarts with or without a build
/// waiting, and asks `/update/restart` only when the bridge answers `404` to it. A refusal is the
/// machine's own answer and comes back as a status; a real failure is thrown and is never sent
/// down the other route.
@Suite(.serialized) struct ClaudeCodeRestartRouteTests {
    private static func backend() -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://restart.test:4098")!)
        return ClaudeCodeBackend(config: config, agentType: .claudeCode, http: http)
    }

    @Test func aCurrentBridgeIsAskedOnTheRestartRouteOnly() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(202, #"{"version":"1.10.0","phase":"waiting"}"#, at: "/restart")
        bridge.publish(202, #"{"version":"1.9.2","phase":"restarting"}"#, at: "/update/restart")
        let backend = Self.backend()
        let restartBefore = bridge.hitCount("/restart")
        let legacyBefore = bridge.hitCount("/update/restart")

        let status = try await backend.restartServer()

        #expect(status.phase == .waiting)
        #expect(status.isRunning)
        #expect(bridge.hitCount("/restart") - restartBefore == 1)
        #expect(bridge.hitCount("/update/restart") - legacyBefore == 0)
    }

    /// A bridge from before `/restart` answers `404` to it, and only then is the route it knows
    /// asked instead.
    @Test func aBridgeFromBeforeTheRouteIsAskedOnTheOldRoute() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(404, nil, at: "/restart")
        bridge.publish(202, #"{"version":"1.9.2","phase":"restarting"}"#, at: "/update/restart")
        let backend = Self.backend()
        let restartBefore = bridge.hitCount("/restart")
        let legacyBefore = bridge.hitCount("/update/restart")

        let status = try await backend.restartServer()

        #expect(status.phase == .restarting)
        #expect(status.isRunning)
        #expect(bridge.hitCount("/restart") - restartBefore == 1)
        #expect(bridge.hitCount("/update/restart") - legacyBefore == 1)
    }

    /// A `409` is the machine saying why nothing was started, so it returns normally with that
    /// reason and never reaches the fallback route.
    @Test func aRefusalReturnsItsReasonAndNeverFallsBack() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(
            409,
            #"""
            {"version":"1.10.0","phase":"idle",
             "reason":"An update is already under way on that machine."}
            """#,
            at: "/restart")
        bridge.publish(202, #"{"version":"1.9.2","phase":"restarting"}"#, at: "/update/restart")
        let backend = Self.backend()
        let legacyBefore = bridge.hitCount("/update/restart")

        let status = try await backend.restartServer()

        #expect(status.isRunning == false)
        #expect(status.reason == "An update is already under way on that machine.")
        #expect(bridge.hitCount("/update/restart") - legacyBefore == 0)
    }

    /// An old bridge that also refuses answers `409` on the route it knows, and that refusal is
    /// the status returned.
    @Test func anOldBridgeThatRefusesReturnsItsReason() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(404, nil, at: "/restart")
        bridge.publish(
            409,
            #"""
            {"version":"1.9.2","phase":"idle",
             "reason":"This bridge is already running the build in its checkout."}
            """#,
            at: "/update/restart")
        let backend = Self.backend()
        let restartBefore = bridge.hitCount("/restart")
        let legacyBefore = bridge.hitCount("/update/restart")

        let status = try await backend.restartServer()

        #expect(status.isRunning == false)
        #expect(status.reason == "This bridge is already running the build in its checkout.")
        #expect(bridge.hitCount("/restart") - restartBefore == 1)
        #expect(bridge.hitCount("/update/restart") - legacyBefore == 1)
    }

    /// A `500` is a real failure, so it throws. The fallback route would have answered and is
    /// published to prove it is not taken.
    @Test func aRealFailureThrowsAndNeverFallsBack() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(500, "oops", at: "/restart")
        bridge.publish(202, #"{"version":"1.9.2","phase":"restarting"}"#, at: "/update/restart")
        let backend = Self.backend()
        let legacyBefore = bridge.hitCount("/update/restart")

        do {
            _ = try await backend.restartServer()
            Issue.record("A 500 from /restart returned instead of throwing")
        } catch AgentError.http(let status, _) {
            #expect(status == 500)
        }

        #expect(bridge.hitCount("/update/restart") - legacyBefore == 0)
    }
}
