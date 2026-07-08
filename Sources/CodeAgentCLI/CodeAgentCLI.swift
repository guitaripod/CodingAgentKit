import ArgumentParser
import CodingAgentKit
import Foundation

@main
struct CodeAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codeagent",
        abstract: "Cross-platform CLI for opencode and Claude Code over HTTP + SSE.",
        subcommands: [
            Health.self, Discover.self, Sessions.self, New.self, Send.self, Stream.self, Diff.self,
            Files.self, Find.self, Providers.self,
        ]
    )
}

struct Health: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check backend health and status.")
    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let backend = try connection.makeBackend()
        let health = try await backend.health()
        print("healthy: \(health.healthy)" + (health.version.map { "  version: \($0)" } ?? ""))
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List sessions.")
    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let sessions = try await connection.makeBackend().listSessions()
        if sessions.isEmpty {
            print("(no sessions)")
            return
        }
        for session in sessions {
            print("\(session.id)  \(session.title)")
        }
    }
}

struct New: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a session and print its id.")
    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let session = try await connection.makeBackend().createSession(title: nil, directory: nil)
        print(session.id)
    }
}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send a prompt and stream the response until the agent goes idle.")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Session id.") var session: String
    @Argument(help: "Prompt text.") var prompt: String
    @Option(name: .long, help: "Model as providerID/modelID (opencode only).") var model: String?
    @Option(name: .long, help: "Attach a file to the prompt (repeatable, opencode only).")
    var attach: [String] = []

    func run() async throws {
        let backend = try connection.makeBackend()
        let selection = model.flatMap(ModelSelection.init(string:))
        let attachments = try attach.map(loadAttachment)
        try await ConversationRunner.run(
            backend: backend, sessionID: session, send: prompt, model: selection,
            attachments: attachments, followForever: false)
    }
}

struct Discover: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Probe the URL and report which backend answers.")
    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let outcome = await ConnectionProbe().probe(
            baseURL: try connection.resolvedURL(), credentials: connection.credentials())
        switch outcome {
        case .ok(let agentType, let version):
            print("ok: \(agentType.displayName)" + (version.map { " (\($0))" } ?? ""))
        case .authFailed:
            print("auth failed — check credentials")
        case .unreachable(let detail):
            print("unreachable: \(detail)")
        case .notAnAgentServer:
            print("reachable, but not an opencode or Claude Code server")
        }
    }
}

struct Stream: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream a session's events until interrupted.")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Session id.") var session: String

    func run() async throws {
        let backend = try connection.makeBackend()
        try await ConversationRunner.run(
            backend: backend, sessionID: session, send: nil, model: nil, followForever: true)
    }
}

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show a session's file diffs (opencode only).")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Session id.") var session: String

    func run() async throws {
        let backend = try requireFileBrowsing(connection, feature: "diff")
        let diffs = try await backend.diff(sessionID: session)
        if diffs.isEmpty {
            print("(no changes)")
            return
        }
        for diff in diffs {
            print("\(diff.path)  +\(diff.additions) -\(diff.deletions)")
        }
    }
}

struct Files: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List files at a path (opencode only).")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Path (default: .).") var path: String = "."

    func run() async throws {
        let backend = try requireFileBrowsing(connection, feature: "files")
        for node in try await backend.listFiles(path: path) {
            print((node.isDirectory ? "d " : "  ") + node.path)
        }
    }
}

struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search file contents (opencode only).")
    @OptionGroup var connection: ConnectionOptions
    @Argument(help: "Pattern.") var pattern: String

    func run() async throws {
        let backend = try requireFileBrowsing(connection, feature: "find")
        for line in try await backend.find(pattern: pattern) {
            print(line)
        }
    }
}

struct Providers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List providers and models (opencode only).")
    @OptionGroup var connection: ConnectionOptions

    func run() async throws {
        let backend = try requireFileBrowsing(connection, feature: "providers")
        for provider in try await backend.providers() {
            print("\(provider.id)\(provider.defaultModelID.map { " (default: \($0))" } ?? "")")
            for model in provider.models.prefix(8) {
                print("   \(model.id)")
            }
            if provider.models.count > 8 {
                print("   … \(provider.models.count - 8) more")
            }
        }
    }
}

private func requireFileBrowsing(_ connection: ConnectionOptions, feature: String) throws
    -> any FileBrowsingBackend
{
    guard let backend = try connection.makeBackend() as? FileBrowsingBackend else {
        throw ValidationError("\(feature) is only supported by the opencode backend")
    }
    return backend
}

private func loadAttachment(_ path: String) throws -> PromptAttachment {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return PromptAttachment(
        mime: mimeType(forExtension: url.pathExtension),
        filename: url.lastPathComponent,
        data: data)
}

private func mimeType(forExtension ext: String) -> String {
    switch ext.lowercased() {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "pdf": return "application/pdf"
    case "txt", "md": return "text/plain"
    case "json": return "application/json"
    default: return "application/octet-stream"
    }
}
