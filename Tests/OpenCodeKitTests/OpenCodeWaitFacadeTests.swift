import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

private func unreachable() -> ServerConfig {
    ServerConfig(baseURL: URL(string: "http://127.0.0.1:1")!, credentials: nil)
}

@Suite struct OpenCodeWaitFacadeTests {
    /// 1.x has no wait-without-sending route in any of its releases, which is a fact about the
    /// API generation rather than about how old this particular server is.
    @Test func v1IsUnavailableByGenerationRatherThanTooOld() async {
        let backend = OpenCodeV1Backend(config: unreachable())
        #expect(await backend.turnWaitSupport() == .unavailable(.generation))
    }

    /// V1 offers no override for the request or the result, so both fall back to the protocol's
    /// own defaults: no request to offer, and no reading of a result nothing should ever produce.
    @Test func v1FallsBackToTheProtocolDefaultsForRequestAndResult() async throws {
        let backend = OpenCodeV1Backend(config: unreachable())
        #expect(try await backend.turnWaitRequest(for: "s") == nil)
        await #expect(throws: (any Error).self) {
            try await backend.turnWaitResult(status: 200, headers: [:], body: Data(), sessionID: "s")
        }
    }

    /// Neither generation overrides device-push registration, so the facade's receipt is the
    /// protocol default: a plain acknowledgement with no verdict on delivery.
    @Test func neitherGenerationSaysAnythingAboutDelivery() async throws {
        let backend = OpenCodeBackend { OpenCodeV2Backend(config: unreachable()) }
        let receipt = try await backend.registerDeviceTokenReceipt(
            DevicePushRegistration(token: "t", environment: "production"))
        #expect(receipt.delivers == nil)
    }

    /// The facade cannot even reach the server, which says nothing about its age or generation —
    /// that must read as undetermined, never as the permanent "too old" a stale connection could
    /// then latch for the rest of the process.
    @Test func theFacadeReportsUndeterminedWhenItCannotEvenReachTheServer() async {
        let backend = OpenCodeBackend { OpenCodeV2Backend(config: unreachable()) }
        #expect(await backend.turnWaitSupport() == .undetermined)
    }

    /// A negotiation failure that genuinely says the generation lacks the route (rather than a
    /// transport failure) still reports too old — the facade only softens the retryable case.
    @Test func theFacadeReportsTooOldWhenNegotiationFailsForAnOtherReason() async {
        let backend = OpenCodeBackend {
            throw AgentError.decoding("malformed /api/info")
        }
        #expect(await backend.turnWaitSupport() == .serverTooOld)
    }
}
