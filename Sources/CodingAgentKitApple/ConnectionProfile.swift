import AgentCore
import ClaudeCodeKit
import Foundation
import OpenCodeKit

public struct ConnectionProfile: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var backend: AgentType
    public var baseURL: URL {
        didSet { baseURL = Self.strippingUserInfo(from: baseURL) }
    }
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
        self.baseURL = Self.strippingUserInfo(from: baseURL)
        self.username = username
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.backend = try container.decode(AgentType.self, forKey: .backend)
        self.baseURL = Self.strippingUserInfo(from: try container.decode(URL.self, forKey: .baseURL))
        self.username = try container.decode(String.self, forKey: .username)
    }

    /// Removes any `user:password@` userinfo from `url` so credentials pasted into a
    /// URL (a common curl/browser habit) never persist to the plaintext
    /// `profiles.json` metadata file or reach request logs. Passwords belong in the
    /// Keychain via ``ConnectionProfileStore``; embedding them in `baseURL` defeats
    /// that split. Returns `url` unchanged when it carries no userinfo or cannot be
    /// decomposed.
    private static func strippingUserInfo(from url: URL) -> URL {
        guard
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.user != nil || components.password != nil
        else { return url }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    public func makeBackend(
        password: String?,
        policy: ConnectionPolicy = .default
    ) -> any CodingAgentBackend {
        switch backend {
        case .openCode:
            let credentials = password.map { BasicCredentials(username: username, password: $0) }
            return OpenCodeBackend(
                config: ServerConfig(baseURL: baseURL, credentials: credentials, policy: policy))
        case .claudeCode:
            let credentials = password.map { BasicCredentials(username: "claude", password: $0) }
            return ClaudeCodeBackend(
                config: ServerConfig(baseURL: baseURL, credentials: credentials, policy: policy))
        }
    }
}
