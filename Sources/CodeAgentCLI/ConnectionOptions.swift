import ArgumentParser
import CodingAgentKit
import Foundation

enum BackendChoice: String, ExpressibleByArgument, Sendable {
    case opencode
    case claude
}

struct ConnectionOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Backend: opencode or claude.")
    var backend: BackendChoice = .opencode

    @Option(
        name: .long,
        help: "Base URL. Default: opencode http://127.0.0.1:4096, claude http://127.0.0.1:3284.")
    var host: String?

    @Option(name: .long, help: "opencode basic-auth username.")
    var username: String = "opencode"

    @Option(name: .long, help: "opencode basic-auth password (or OPENCODE_SERVER_PASSWORD).")
    var password: String?

    func makeBackend() throws -> any CodingAgentBackend {
        let environment = ProcessInfo.processInfo.environment
        switch backend {
        case .opencode:
            let url = try resolveURL(
                host ?? environment["OPENCODE_HOST"] ?? "http://127.0.0.1:4096")
            let resolvedPassword = password ?? environment["OPENCODE_SERVER_PASSWORD"]
            let resolvedUser = environment["OPENCODE_SERVER_USERNAME"] ?? username
            let credentials = resolvedPassword.map {
                BasicCredentials(username: resolvedUser, password: $0)
            }
            return OpenCodeBackend(config: ServerConfig(baseURL: url, credentials: credentials))
        case .claude:
            let url = try resolveURL(
                host ?? environment["BRIDGE_HOST"] ?? "http://127.0.0.1:4098")
            let resolvedPassword = password ?? environment["BRIDGE_PASSWORD"]
            let credentials = resolvedPassword.map {
                BasicCredentials(username: "claude", password: $0)
            }
            return ClaudeSDKBackend(config: ServerConfig(baseURL: url, credentials: credentials))
        }
    }

    private func resolveURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw ValidationError("Invalid URL: \(string)")
        }
        return url
    }

    func resolvedURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        switch backend {
        case .opencode:
            return try resolveURL(host ?? environment["OPENCODE_HOST"] ?? "http://127.0.0.1:4096")
        case .claude:
            return try resolveURL(host ?? environment["AGENTAPI_HOST"] ?? "http://127.0.0.1:3284")
        }
    }

    func credentials() -> BasicCredentials? {
        let environment = ProcessInfo.processInfo.environment
        guard backend == .opencode else { return nil }
        guard let resolvedPassword = password ?? environment["OPENCODE_SERVER_PASSWORD"] else {
            return nil
        }
        let resolvedUser = environment["OPENCODE_SERVER_USERNAME"] ?? username
        return BasicCredentials(username: resolvedUser, password: resolvedPassword)
    }
}
