import Foundation

public struct ConnectionProbe: Sendable {
    public enum Outcome: Sendable, Hashable {
        case ok(agentType: AgentType, version: String?)
        case authFailed
        case unreachable(String)
        case notAnAgentServer
    }

    public init() {}

    /// Probes a base URL and classifies it: which agent backend (if any) answers, or why it failed.
    public func probe(
        baseURL: URL,
        credentials: BasicCredentials? = nil,
        policy: ConnectionPolicy = .default
    ) async -> Outcome {
        let builder = RequestBuilder(
            config: ServerConfig(baseURL: baseURL, credentials: credentials, policy: policy))
        let http = HTTPClient(policy: policy, logger: AgentLog.logger("probe"))

        do {
            let data = try await http.send(builder.request(.get, "/global/health"))
            if let health = try? JSONCoding.decoder.decode(HealthProbe.self, from: data),
                (health.healthy ?? false) || health.version != nil
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
            let data = try await http.send(builder.request(.get, "/status"))
            if let status = try? JSONCoding.decoder.decode(StatusProbe.self, from: data),
                status.agent == "claude" || status.status != nil
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
