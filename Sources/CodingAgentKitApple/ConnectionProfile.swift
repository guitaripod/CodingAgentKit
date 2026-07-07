import AgentCore
import ClaudeCodeKit
import Foundation
import OpenCodeKit

public struct ConnectionProfile: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var backend: AgentType
    public var baseURL: URL
    public var username: String

    public init(
        id: String,
        name: String,
        backend: AgentType,
        baseURL: URL,
        username: String = "opencode"
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.baseURL = baseURL
        self.username = username
    }

    public func makeBackend(
        password: String?,
        policy: ConnectionPolicy = .default
    ) -> any CodingAgentBackend {
        let credentials = password.map { BasicCredentials(username: username, password: $0) }
        switch backend {
        case .openCode:
            return OpenCodeBackend(
                config: ServerConfig(baseURL: baseURL, credentials: credentials, policy: policy))
        case .claudeCode:
            return ClaudeCodeBackend(
                config: ServerConfig(baseURL: baseURL, credentials: credentials, policy: policy))
        }
    }
}
