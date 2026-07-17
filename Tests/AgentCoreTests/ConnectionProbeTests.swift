import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

private enum ProbeEndpoint: Equatable { case health, status, other }

/// Classifies a probe request by which endpoint it targets, robust to how
/// Foundation encodes the appended path component.
private func endpoint(of request: URLRequest) -> ProbeEndpoint {
    let target = request.url?.absoluteString ?? ""
    if target.contains("health") { return .health }
    if target.contains("status") { return .status }
    return .other
}

private actor ProbeRecorder {
    private(set) var requests: [String] = []
    var count: Int { requests.count }

    func record(_ url: String) { requests.append(url) }

    func recordAndCount(_ url: String) -> Int {
        requests.append(url)
        return requests.count
    }
}

/// Builds a `ConnectionProbe` transport that dispatches by endpoint and, when
/// given a recorder, logs every request URL so invocation counts are assertable.
private func makeTransport(
    record: ProbeRecorder? = nil,
    _ handler: @escaping @Sendable (ProbeEndpoint) async throws -> Data
) -> @Sendable (URLRequest) async throws -> Data {
    { request in
        if let record { await record.record(request.url?.absoluteString ?? "") }
        return try await handler(endpoint(of: request))
    }
}

@Suite struct ConnectionProbeTests {
    static let base = URL(string: "http://100.64.0.1:4098")!

    @Test func opencodeHealthClassifiesAsOpenCodeWithVersion() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                endpoint == .health
                    ? Data(#"{"healthy":true,"version":"0.4.2"}"#.utf8)
                    : Data("{}".utf8)
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .openCode, version: "0.4.2"))
    }

    @Test func openCodeHealthyFalseStillClassifiesAsOpenCodeWithNilVersion() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                endpoint == .health ? Data(#"{"healthy":false}"#.utf8) : Data("{}".utf8)
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .openCode, version: nil))
    }

    @Test func openCodeVersionOnlyWithoutHealthyStillClassifiesAsOpenCode() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                endpoint == .health ? Data(#"{"version":"9.9.9"}"#.utf8) : Data("{}".utf8)
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .openCode, version: "9.9.9"))
    }

    @Test func healthNotAnAgentButStatusClaudeClassifiesAsClaudeWithAgentVersion() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                switch endpoint {
                case .health: return Data(#"{"service":"nginx"}"#.utf8)
                default: return Data(#"{"status":"ok","agent":"claude-code-1.0"}"#.utf8)
                }
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .claudeCode, version: "claude-code-1.0"))
    }

    @Test func claudeStatusAgentTypeFieldUsedAsVersionFallback() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                switch endpoint {
                case .health: return Data("{}".utf8)
                default: return Data(#"{"agent_type":"claudeCode"}"#.utf8)
                }
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .claudeCode, version: "claudeCode"))
    }

    @Test func claudeStatusWithOnlyStatusFieldHasNilVersion() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                switch endpoint {
                case .health: return Data("{}".utf8)
                default: return Data(#"{"status":"running"}"#.utf8)
                }
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .claudeCode, version: nil))
    }

    @Test func healthServerErrorFallsThroughToStatusClaudeProbe() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                switch endpoint {
                case .health: throw AgentError.http(status: 500, body: "boom")
                default: return Data(#"{"agent":"claude-code"}"#.utf8)
                }
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .ok(agentType: .claudeCode, version: "claude-code"))
    }

    @Test func http401OnHealthClassifiesAsAuthFailed() async {
        let probe = ConnectionProbe(
            transport: makeTransport { _ in
                throw AgentError.http(status: 401, body: "unauthorized")
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .authFailed)
    }

    @Test func http403OnHealthClassifiesAsAuthFailed() async {
        let probe = ConnectionProbe(
            transport: makeTransport { _ in
                throw AgentError.http(status: 403, body: "forbidden")
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .authFailed)
    }

    @Test func authFailureOnStatusEndpointClassifiesAsAuthFailed() async {
        let probe = ConnectionProbe(
            transport: makeTransport { endpoint in
                switch endpoint {
                case .health: return Data(#"{"service":"nginx"}"#.utf8)
                default: throw AgentError.http(status: 403, body: "")
                }
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .authFailed)
    }

    @Test func connectionErrorClassifiesAsUnreachablePreservingDetail() async {
        let probe = ConnectionProbe(
            transport: makeTransport { _ in
                throw AgentError.connection("connection refused")
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .unreachable("connection refused"))
    }

    @Test func unrecognizedJSONOnBothEndpointsClassifiesAsNotAnAgentServer() async {
        let probe = ConnectionProbe(
            transport: makeTransport { _ in Data(#"{"foo":"bar"}"#.utf8) })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .notAnAgentServer)
    }

    @Test func invalidJSONOnBothEndpointsClassifiesAsNotAnAgentServer() async {
        let probe = ConnectionProbe(
            transport: makeTransport { _ in Data("<html>not json</html>".utf8) })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .notAnAgentServer)
    }

    @Test func serverErrorOnBothEndpointsClassifiesAsNotAnAgentServer() async {
        let probe = ConnectionProbe(
            transport: makeTransport { _ in
                throw AgentError.http(status: 500, body: "boom")
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .notAnAgentServer)
    }

    @Test func retryUnreachableFalseAttemptsProbeExactlyOnce() async {
        let recorder = ProbeRecorder()
        let probe = ConnectionProbe(
            transport: makeTransport(record: recorder) { _ in
                throw AgentError.connection("refused")
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: false)
        #expect(outcome == .unreachable("refused"))
        #expect(await recorder.count == 1)
    }

    @Test func retryUnreachableTrueDoesNotRetryNonUnreachableOutcomes() async {
        let recorder = ProbeRecorder()
        let probe = ConnectionProbe(
            transport: makeTransport(record: recorder) { _ in
                throw AgentError.http(status: 401, body: "")
            })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: true)
        #expect(outcome == .authFailed)
        #expect(await recorder.count == 1)
    }

    @Test func retryUnreachableTrueRetriesOnceAndReturnsSecondAttemptOutcome() async {
        let recorder = ProbeRecorder()
        let probe = ConnectionProbe(transport: { request in
            let attempt = await recorder.recordAndCount(request.url?.absoluteString ?? "")
            if attempt == 1 { throw AgentError.connection("transient") }
            return Data(#"{"version":"0.5.0"}"#.utf8)
        })
        let outcome = await probe.probe(baseURL: Self.base, retryUnreachable: true)
        #expect(outcome == .ok(agentType: .openCode, version: "0.5.0"))
        #expect(await recorder.count == 2)
    }
}
