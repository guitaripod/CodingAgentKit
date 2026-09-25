import AgentTestSupport
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

private func decodeResult(_ json: String) throws -> TurnWaitResult {
    try JSONCoding.decoder.decode(TurnWaitResult.self, from: Data(json.utf8))
}

@Suite struct TurnWaitResultDecodingTests {
    /// The heartbeat writes a blank line before the real object; RFC 8259 leading whitespace is
    /// valid JSON, and a client that decoded the whole held connection at once must not choke on
    /// exactly the bytes the bridge is documented to send first.
    @Test func aLeadingBlankLineIsSkipped() throws {
        let result = try decodeResult("\n\n{\"state\":\"ended\",\"waited\":true,\"ending\":\"finished\"}")
        #expect(result.state == .ended)
        #expect(result.waited)
        #expect(result.ending == .finished)
    }

    /// An `ending` this build predates decodes to `nil` rather than failing the whole result —
    /// the wire contract can only ever add cases to this enum.
    @Test func anUnknownEndingDecodesAsNil() throws {
        let result = try decodeResult(
            "{\"state\":\"ended\",\"waited\":true,\"ending\":\"reincarnated\"}")
        #expect(result.state == .ended)
        #expect(result.ending == nil)
    }

    /// A `state` this build has never heard of is the one thing this contract cannot shrug off:
    /// there is no reading of the result left once the field the caller branches on is unknown.
    @Test func anUnknownStateFailsToDecode() {
        #expect(throws: (any Error).self) {
            try decodeResult("{\"state\":\"orbiting\",\"waited\":true}")
        }
    }

    /// Fields neither side has agreed on yet are ignored rather than rejected.
    @Test func extraFieldsAreIgnored() throws {
        let result = try decodeResult(
            "{\"state\":\"running\",\"waited\":false,\"futureField\":{\"a\":1},\"another\":[1,2,3]}")
        #expect(result.state == .running)
        #expect(!result.waited)
    }

    /// `waited` is documented as always present, but a caller reading a body it does not fully
    /// control should not crash on a server that left it out.
    @Test func waitedDefaultsToFalseWhenMissing() throws {
        let result = try decodeResult("{\"state\":\"running\"}")
        #expect(!result.waited)
    }

    @Test func endedAtParsesWithFractionalSeconds() throws {
        let result = try decodeResult(
            "{\"state\":\"ended\",\"waited\":true,\"endedAt\":\"2026-09-25T12:00:00.500Z\"}")
        #expect(result.endedAt == Date(timeIntervalSince1970: 1_790_337_600.5))
    }

    @Test func endedAtParsesWithoutFractionalSeconds() throws {
        let result = try decodeResult(
            "{\"state\":\"ended\",\"waited\":true,\"endedAt\":\"2026-09-25T12:00:00Z\"}")
        #expect(result.endedAt == Date(timeIntervalSince1970: 1_790_337_600))
    }

    /// A malformed timestamp is read as "no timestamp" rather than failing the whole result — the
    /// rest of the body still says whether the turn is over.
    @Test func aMalformedEndedAtIsDroppedRatherThanThrown() throws {
        let result = try decodeResult(
            "{\"state\":\"ended\",\"waited\":true,\"endedAt\":\"not a date\"}")
        #expect(result.endedAt == nil)
    }

    /// Every field round-trips through this build's own encoder, which is what a client holding a
    /// result across a relaunch (or a test fixture) depends on.
    @Test func encodingRoundTrips() throws {
        let original = TurnWaitResult(
            state: .ended, waited: true, ending: .approval, title: "Ship it",
            toolCount: 4, background: 1, duration: 192.4, lastMessageID: "m9",
            endedAt: Date(timeIntervalSince1970: 1_790_337_600.5))
        let data = try JSONCoding.encoder.encode(original)
        let decoded = try JSONCoding.decoder.decode(TurnWaitResult.self, from: data)
        #expect(decoded == original)
    }
}

@Suite struct TurnWaitProtocolDefaultTests {
    /// A backend that answers nothing about waiting at all — the base case every existing
    /// conformer that has not adopted this capability yet keeps working under.
    private struct SilentBackend: CodingAgentBackend {
        let agentType: AgentType = .openCode
        let capabilities = BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: false, supportsModelSelection: false,
            supportsAttachments: false, supportsAbort: false)

        func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
        func listSessions() async throws -> [AgentSession] { [] }
        func createSession(title: String?, directory: String?) async throws -> AgentSession {
            AgentSession(
                id: "s", agentType: agentType, title: title ?? "s", createdAt: Date(),
                updatedAt: Date())
        }
        func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
        func send(_ prompt: SendPrompt, to sessionID: String) async throws {}
        func abort(sessionID: String) async throws {}
        func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test func aBackendWithNoOverrideOffersNoRequest() async throws {
        let backend = SilentBackend()
        #expect(try await backend.turnWaitRequest(for: "s") == nil)
    }

    @Test func aBackendWithNoOverrideReportsUnavailable() async {
        let backend = SilentBackend()
        #expect(await backend.turnWaitSupport() == .unavailable(.none))
    }

    @Test func aBackendWithNoOverrideThrowsOnAResult() async {
        let backend = SilentBackend()
        await #expect(throws: (any Error).self) {
            try await backend.turnWaitResult(status: 200, headers: [:], body: Data(), sessionID: "s")
        }
    }

    @Test func aBackendWithNoPushOverrideStillAnswersAReceiptWithNoVerdict() async throws {
        let backend = SilentBackend()
        let receipt = try await backend.registerDeviceTokenReceipt(
            DevicePushRegistration(token: "t", environment: "production"))
        #expect(receipt.delivers == nil)
    }
}
