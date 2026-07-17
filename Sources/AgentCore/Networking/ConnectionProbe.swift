import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct ConnectionProbe: Sendable {
    public enum Outcome: Sendable, Hashable {
        case ok(agentType: AgentType, version: String?)
        case authFailed
        case unreachable(String)
        case notAnAgentServer
    }

    typealias Transport = @Sendable (URLRequest) async throws -> Data

    private let transportProvider: @Sendable (ConnectionPolicy) async -> Transport

    public init() {
        let pool = HTTPClientPool()
        self.transportProvider = { policy in
            let client = await pool.client(for: policy)
            return { try await client.send($0) }
        }
    }

    /// Testing seam: routes every probe request through `transport` instead
    /// of a real `HTTPClient`, so outcome classification is exercisable
    /// without a server.
    init(transport: @escaping Transport) {
        self.transportProvider = { _ in transport }
    }

    /// Probes a base URL and classifies it: which agent backend (if any) answers, or why it failed.
    /// The unreachable retry smooths over transient flakiness for a single
    /// interactive connect; bulk scans must pass `retryUnreachable: false` —
    /// a blackholed host would otherwise cost two full timeouts plus the gap.
    public func probe(
        baseURL: URL,
        credentials: BasicCredentials? = nil,
        policy: ConnectionPolicy = .default,
        retryUnreachable: Bool = true
    ) async -> Outcome {
        let transport = await transportProvider(policy)
        let outcome = await attemptProbe(
            baseURL: baseURL, credentials: credentials, policy: policy, transport: transport)
        if retryUnreachable, case .unreachable = outcome, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            return await attemptProbe(
                baseURL: baseURL, credentials: credentials, policy: policy, transport: transport)
        }
        return outcome
    }

    private func attemptProbe(
        baseURL: URL,
        credentials: BasicCredentials?,
        policy: ConnectionPolicy,
        transport: Transport
    ) async -> Outcome {
        let builder = RequestBuilder(
            config: ServerConfig(baseURL: baseURL, credentials: credentials, policy: policy))

        do {
            let data = try await transport(builder.request(.get, "/global/health"))
            if let health = try? JSONCoding.decoder.decode(HealthProbe.self, from: data),
                health.healthy != nil || health.version != nil
            {
                return .ok(agentType: .openCode, version: health.version)
            }
        } catch let error as AgentError {
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                return .authFailed
            case .connection(let detail):
                return .unreachable(detail)
            default:
                break
            }
        } catch {
        }

        do {
            let data = try await transport(builder.request(.get, "/status"))
            if let status = try? JSONCoding.decoder.decode(StatusProbe.self, from: data),
                status.status != nil || status.agent != nil || status.agentType != nil
            {
                return .ok(agentType: .claudeCode, version: status.agent ?? status.agentType)
            }
        } catch let error as AgentError {
            switch error {
            case .http(let httpStatus, _) where httpStatus == 401 || httpStatus == 403:
                return .authFailed
            case .connection(let detail):
                return .unreachable(detail)
            default:
                break
            }
        } catch {
        }

        return .notAnAgentServer
    }

    private struct HealthProbe: Decodable {
        let healthy: Bool?
        let version: String?
    }

    private struct StatusProbe: Decodable {
        let status: String?
        let agentType: String?
        let agent: String?

        enum CodingKeys: String, CodingKey {
            case status
            case agentType = "agent_type"
            case agent
        }
    }
}

/// Hands out one `HTTPClient` per distinct policy for the lifetime of a
/// `ConnectionProbe`, so bulk tailnet scans (hundreds of attempts) reuse a
/// single client instead of allocating two fresh `URLSession`s per attempt.
private actor HTTPClientPool {
    private var clients: [ConnectionPolicy: HTTPClient] = [:]

    func client(for policy: ConnectionPolicy) -> HTTPClient {
        if let existing = clients[policy] { return existing }
        let created = HTTPClient(policy: policy, logger: AgentLog.logger("probe"))
        clients[policy] = created
        return created
    }
}
