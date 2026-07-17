import Foundation
import Testing

@testable import AgentCore

@Suite struct CoreUnitFixTests {
    @Test func permanentClientHTTPStatusesAreNotRetryable() {
        for status in [400, 401, 403, 404, 409, 418, 422] {
            #expect(!AgentError.http(status: status, body: "").isRetryable)
        }
    }

    @Test func retryFriendlyClientHTTPStatusesAreRetryable() {
        for status in [408, 425, 429] {
            #expect(AgentError.http(status: status, body: "").isRetryable)
        }
    }

    @Test func serverHTTPStatusesAreRetryable() {
        for status in [500, 502, 503, 504] {
            #expect(AgentError.http(status: status, body: "").isRetryable)
        }
    }

    @Test func transportAndServerErrorsAreRetryable() {
        #expect(AgentError.connection("dropped").isRetryable)
        #expect(AgentError.server("overloaded").isRetryable)
    }

    @Test func structuralClientErrorsAreNotRetryable() {
        #expect(!AgentError.decoding("bad json").isRetryable)
        #expect(!AgentError.invalidURL("nope").isRetryable)
        #expect(!AgentError.unsupported("feature").isRetryable)
    }

    @Test func metadataFreeUpsertDoesNotEraseKnownCostTokensProviderModel() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m", role: .assistant, agentType: .openCode,
                    parts: [MessagePart(id: "p", kind: .text("done"))],
                    createdAt: Date(timeIntervalSince1970: 0),
                    costUSD: 0.05, providerID: "anthropic", modelID: "claude-x",
                    totalTokens: 1234),
                replaceParts: true))
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m", role: .assistant, agentType: .openCode,
                    parts: [], createdAt: Date(timeIntervalSince1970: 0),
                    isStreaming: true,
                    costUSD: nil, providerID: nil, modelID: nil, totalTokens: nil),
                replaceParts: false))

        let merged = reducer.snapshot.first
        #expect(merged?.costUSD == 0.05)
        #expect(merged?.totalTokens == 1234)
        #expect(merged?.providerID == "anthropic")
        #expect(merged?.modelID == "claude-x")
    }

    @Test func laterUpsertWithNewMetadataOverwritesPreviousValues() {
        var reducer = MessageReducer(agentType: .openCode)
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m", role: .assistant, agentType: .openCode,
                    createdAt: Date(timeIntervalSince1970: 0),
                    costUSD: 0.05, providerID: "anthropic", modelID: "claude-x",
                    totalTokens: 1234),
                replaceParts: false))
        reducer.apply(
            .messageUpserted(
                ChatMessage(
                    id: "m", role: .assistant, agentType: .openCode,
                    createdAt: Date(timeIntervalSince1970: 0),
                    costUSD: 0.09, providerID: "openai", modelID: "gpt-x",
                    totalTokens: 2000),
                replaceParts: false))

        let merged = reducer.snapshot.first
        #expect(merged?.costUSD == 0.09)
        #expect(merged?.totalTokens == 2000)
        #expect(merged?.providerID == "openai")
        #expect(merged?.modelID == "gpt-x")
    }

    @Test func ipv6LiteralIsClassifiedAsAddressNotName() {
        let name = suggestion("host.tail.ts.net")
        let ipv6 = suggestion("[fd7a:115c::53]")
        #expect(ipv6.baseURL.host?.contains("fd7a") == true)
        #expect(TailnetScanner.preferred(name, over: ipv6))
        #expect(!TailnetScanner.preferred(ipv6, over: name))
    }

    @Test func ipv4LiteralIsClassifiedAsAddressNotName() {
        let name = suggestion("host.tail.ts.net")
        let ipv4 = suggestion("100.64.0.1")
        #expect(TailnetScanner.preferred(name, over: ipv4))
        #expect(!TailnetScanner.preferred(ipv4, over: name))
    }

    @Test func magicDNSNameOutranksBothAddressFamilies() {
        let name = suggestion("host.tail.ts.net")
        let ipv4 = suggestion("100.64.0.1")
        let ipv6 = suggestion("[fd7a:115c::53]")
        #expect(TailnetScanner.preferred(name, over: ipv4))
        #expect(TailnetScanner.preferred(name, over: ipv6))
    }

    private func suggestion(_ host: String, auth: Bool = false) -> TailnetScanner.Suggestion {
        TailnetScanner.Suggestion(
            id: host, name: host, baseURL: URL(string: "http://\(host):4098")!,
            backend: .claudeCode, version: nil, requiresAuth: auth,
            recommendedProfileName: "host", os: nil, lastSeen: nil)
    }
}
