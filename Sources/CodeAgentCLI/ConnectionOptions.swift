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
                host ?? environment["AGENTAPI_HOST"] ?? "http://127.0.0.1:3284")
            return ClaudeCodeBackend(config: ServerConfig(baseURL: url))
        }
    }

    private func resolveURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw ValidationError("Invalid URL: \(string)")
        }
        return url
    }
}

extension ModelSelection {
    static func parse(_ raw: String) -> ModelSelection? {
        guard let slash = raw.firstIndex(of: "/") else { return nil }
        let provider = String(raw[..<slash])
        let model = String(raw[raw.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return ModelSelection(providerID: provider, modelID: model)
    }
}
