import AgentCore
import Foundation

public struct OpenCodeBackend: FileBrowsingBackend {
    public let agentType: AgentType = .openCode
    public let capabilities = BackendCapabilities(
        supportsFileBrowsing: true,
        supportsDiffs: true,
        supportsPermissions: true,
        supportsMultipleSessions: true,
        supportsModelSelection: true,
        supportsAttachments: true,
        supportsReasoningEffort: true,
        supportsAbort: true,
        supportsSessionUsage: false,
        supportsQuestions: true,
        supportsSubagents: true,
        supportsCommands: true
    )

    let client: OpenCodeClient
    private let directories = SessionDirectoryCache()

    public init(config: ServerConfig) {
        self.client = OpenCodeClient(config: config)
    }

    public init(client: OpenCodeClient) {
        self.client = client
    }

    /// opencode scopes `/event` and `/question` by workspace directory, so
    /// per-session calls need the session's directory. Cached; refreshed from
    /// the session list on miss.
    private actor SessionDirectoryCache {
        private var directories: [String: String] = [:]

        func directory(for sessionID: String, client: OpenCodeClient) async -> String? {
            if let cached = directories[sessionID] { return cached }
            if let sessions = try? await client.listSessions() {
                for session in sessions {
                    if let directory = session.directory {
                        directories[session.id] = directory
                    }
                }
            }
            return directories[sessionID]
        }

        func record(sessionID: String, directory: String?) {
            guard let directory else { return }
            directories[sessionID] = directory
        }
    }

    public func health() async throws -> ServerHealth {
        let health = try await client.health()
        return ServerHealth(healthy: health.healthy, version: health.version)
    }

    public func listSessions() async throws -> [AgentSession] {
        try await client.listSessions().map(OpenCodeMapping.session)
    }

    public func projects() async throws -> [AgentProject] {
        try await client.projects().compactMap(OpenCodeMapping.project)
    }

    public func listSessions(inWorktree worktree: String?) async throws -> [AgentSession] {
        guard let worktree else { return try await listSessions() }
        return try await client.listSessions(directory: worktree).map(OpenCodeMapping.session)
    }

    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        let session = OpenCodeMapping.session(
            try await client.createSession(title: title, directory: directory))
        await directories.record(sessionID: session.id, directory: session.directory)
        return session
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await client.deleteSession(sessionID)
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await client.messages(sessionID: sessionID).map(OpenCodeMapping.message)
    }

    /// opencode gives a spawned agent a session of its own, parented to the one
    /// that spawned it. Those children are subagents, not conversations: they
    /// are reported here so a client can nest them under their parent rather
    /// than list them as chats in their own right.
    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        let sessions: [OCSession]
        if let directory = await directories.directory(for: sessionID, client: client) {
            sessions = (try? await client.listSessions(directory: directory)) ?? []
        } else {
            sessions = (try? await client.listSessions()) ?? []
        }
        return sessions
            .filter { $0.parentID == sessionID }
            .map(OpenCodeMapping.subagent)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        try await client.messages(sessionID: agentID).map(OpenCodeMapping.message)
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        let model = prompt.model.map {
            OCModelInput(providerID: $0.providerID, modelID: $0.modelID)
        }
        var parts: [OCPartInput] = [.text(prompt.text)]
        for attachment in prompt.attachments {
            guard let url = Self.attachmentURL(attachment) else { continue }
            parts.append(.file(mime: attachment.mime, filename: attachment.filename, url: url))
        }
        let request = OCPromptRequest(
            parts: parts, model: model, agent: prompt.agent, variant: prompt.reasoningEffort)
        try await client.promptAsync(sessionID: sessionID, request: request)
    }

    private static func attachmentURL(_ attachment: PromptAttachment) -> String? {
        if let url = attachment.url { return url }
        if let data = attachment.data {
            return "data:\(attachment.mime);base64,\(data.base64EncodedString())"
        }
        return nil
    }

    public func availableModels() async throws -> [ModelInfo] {
        try await providers().flatMap(\.models)
    }

    public func defaultModel() async throws -> ModelSelection? {
        for provider in try await providers() where provider.defaultModelID != nil {
            return ModelSelection(providerID: provider.id, modelID: provider.defaultModelID!)
        }
        return nil
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let directory = await directories.directory(for: sessionID, client: client)
                do {
                    for try await sse in client.eventStream(directory: directory) {
                        if let event = OpenCodeEventDecoder.decode(sse, sessionID: sessionID) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func abort(sessionID: String) async throws {
        try await client.abort(sessionID: sessionID)
    }

    /// opencode's catalog is whatever the server resolves for its own workspace — user and project
    /// command files, MCP prompts, and skills — so `directory` is ignored here.
    public func availableCommands(directory: String?) async throws -> [AgentCommand] {
        try await client.commands().map(Self.command)
    }

    static func command(for command: OCCommand) -> AgentCommand {
        AgentCommand(
            name: command.name,
            details: command.description ?? "",
            argumentHint: argumentHint(for: command),
            source: source(for: command))
    }

    /// `POST /session/:id/command` only answers when the turn it starts has ended, so awaiting it
    /// would leave the caller blocked for the whole turn. The command is dispatched and the result
    /// left to the event stream, matching how `prompt_async` behaves for an ordinary message; a
    /// dispatch failure has no reply channel, so it is logged rather than lost silently.
    public var resolvesCommandsFromPromptText: Bool { false }

    public func runCommand(
        _ command: AgentCommand, arguments: String?, in sessionID: String
    ) async throws {
        let directory = await directories.directory(for: sessionID, client: client)
        let request = OCCommandRequest(
            command: command.name, arguments: arguments, model: nil, agent: nil)
        let client = self.client
        Task.detached {
            do {
                try await client.runCommand(
                    sessionID: sessionID, directory: directory, request: request)
            } catch {
                AgentLog.logger("opencode").error(
                    "command /\(command.name) failed: \(error)")
            }
        }
    }

    private static func source(for command: OCCommand) -> AgentCommand.Source {
        switch command.source {
        case "mcp": return .mcp
        case "skill": return .skill
        case "command": return .custom
        default: return .custom
        }
    }

    /// opencode describes a command's placeholders as template variables (`$ARGUMENTS`, `$1`);
    /// render them the way an argument hint reads elsewhere so one palette can present every
    /// backend's commands identically, without leaking template syntax at the user.
    private static func argumentHint(for command: OCCommand) -> String? {
        guard let hints = command.hints, !hints.isEmpty else { return nil }
        return hints
            .map { hint in
                let bare = hint.hasPrefix("$") ? String(hint.dropFirst()) : hint
                return "<\(bare.uppercased() == "ARGUMENTS" ? "arguments" : bare)>"
            }
            .joined(separator: " ")
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await client.respondPermission(
            sessionID: permission.sessionID,
            permissionID: permission.id,
            response: decision.rawValue
        )
    }

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        let directory = await directories.directory(for: request.sessionID, client: client)
        try await client.answerQuestion(
            requestID: request.id, directory: directory, answers: answers)
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        let directory = await directories.directory(for: request.sessionID, client: client)
        try await client.rejectQuestion(requestID: request.id, directory: directory)
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] {
        let directory = await directories.directory(for: sessionID, client: client)
        return try await client.pendingQuestions(directory: directory)
            .compactMap(OpenCodeMapping.question)
            .filter { $0.sessionID == sessionID }
    }

    public func listFiles(path: String?) async throws -> [FileNode] {
        try await client.files(path: path ?? ".").map {
            FileNode(path: $0.path, name: $0.name, isDirectory: $0.type == "directory")
        }
    }

    public func fileContent(path: String) async throws -> String {
        try await client.fileContent(path: path).content
    }

    public func diff(sessionID: String) async throws -> [FileDiff] {
        try await client.diff(sessionID: sessionID).map {
            FileDiff(
                path: $0.file ?? "", additions: $0.additions ?? 0, deletions: $0.deletions ?? 0,
                patch: $0.patch)
        }
    }

    public func find(pattern: String) async throws -> [String] {
        try await client.find(pattern: pattern).compactMap { match in
            guard let path = match.path?.text else { return nil }
            if let line = match.lineNumber { return "\(path):\(line)" }
            return path
        }
    }

    /// The catalog reports variants as a dictionary; the menu wants ascending effort. Known
    /// effort names sort by rank, anything else lands after them alphabetically.
    static func orderedVariants(_ variants: [String: OCModelVariant]?) -> [String]? {
        guard let variants, !variants.isEmpty else { return nil }
        let rank = ["minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5]
        return variants.keys.sorted {
            switch (rank[$0], rank[$1]) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0 < $1
            }
        }
    }

    public func providers() async throws -> [Provider] {
        let response = try await client.providers()
        return response.providers.map { provider in
            let models = (provider.models ?? [:])
                .map {
                    ModelInfo(
                        id: $0.value.id ?? $0.key, name: $0.value.name ?? $0.key,
                        providerID: provider.id,
                        capabilities: $0.value.capabilities.map { caps in
                            ModelCapabilities(
                                attachment: caps.attachment ?? false,
                                imageInput: caps.input?.image ?? false,
                                pdfInput: caps.input?.pdf ?? false)
                        },
                        variants: Self.orderedVariants($0.value.variants))
                }
                .sorted { $0.id < $1.id }
            return Provider(
                id: provider.id,
                name: provider.name ?? provider.id,
                models: models,
                defaultModelID: response.default?[provider.id]
            )
        }
    }
}
