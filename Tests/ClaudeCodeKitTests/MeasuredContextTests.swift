import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// A Claude conversation's window, as the bridge's CLI measured it.
@Suite struct MeasuredContextTests {
    private static func backend(host: String, agentType: AgentType = .claudeCode) -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DetailBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        return ClaudeCodeBackend(
            config: ServerConfig(baseURL: URL(string: "http://\(host):4098")!), agentType: agentType, http: http)
    }

    @Test func theBridgesMeasurementIsRead() async throws {
        let host = "measured.test"
        DetailBridge.shared.publish(
            #"{"model":"claude-opus-5-5","totalTokens":120000,"maxTokens":1000000,"autoCompactAt":967000,"categories":[{"id":"system_prompt","name":"System prompt","tokens":3625,"kind":"used"},{"id":"free_space","name":"Free space","tokens":880000,"kind":"free"}],"messages":{"user":214,"assistant":10,"toolCalls":5,"toolResults":40,"attachments":0,"other":13},"memoryFiles":[],"measuredAt":"2026-11-04T10:00:00Z"}"#,
            at: host + "/sessions/c1/context")
        let measured = try #require(try await Self.backend(host: host).measuredContext(for: "c1"))
        #expect(measured.totalTokens == 120_000)
        #expect(measured.categories.first?.isUsed == true)
        #expect(measured.categories.last?.isUsed == false)
        #expect(measured.messages?.toolResults == 40)
    }

    @Test func anOmpBackendNeverAsks() async throws {
        let host = "measured-omp.test"
        #expect(try await Self.backend(host: host, agentType: .omp).measuredContext(for: "c1") == nil)
        #expect(DetailBridge.shared.reads(host + "/sessions/c1/context") == 0)
    }
}
