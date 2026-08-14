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
        supportsCommands: true,
        supportsCompaction: true
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
    /// the session list on miss — and from `GET /session/:id` when the session
    /// lives outside every known project (home-directory chats, for example).
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
            if let cached = directories[sessionID] { return cached }
            if let projects = try? await client.projects() {
                for project in projects {
                    guard let worktree = project.worktree, !worktree.isEmpty else { continue }
                    guard let sessions = try? await client.listSessions(directory: worktree) else {
                        continue
                    }
                    for session in sessions {
                        if let directory = session.directory {
                            directories[session.id] = directory
                        }
                    }
                }
            }
            if let cached = directories[sessionID] { return cached }
            if let session = try? await client.session(sessionID),
                let directory = session.directory, !directory.isEmpty
            {
                directories[sessionID] = directory
                return directory
            }
            return directories[sessionID]
        }

        func record(sessionID: String, directory: String?) {
            guard let directory, !directory.isEmpty else { return }
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

    /// opencode scopes `/session` to the project the server was launched in unless a worktree is
    /// named, so a complete history is a walk: the server's own project first — the call that
    /// throws when the machine is unreachable — then every project the server knows, then the
    /// places the caller has seen sessions work in that no project owns. Duplicates collapse by
    /// session id, and the result is sorted like the plain listing.
    ///
    /// A spawned agent is given a session of its own here, parented to the one that spawned it.
    /// That is a subagent's transcript, which the conversation renders at the tool call that
    /// spawned it — so it is dropped rather than listed, and the chat that started the work stays
    /// the only chat the work produced.
    public func listAllSessions(knownDirectories: [String]) async throws -> [AgentSession] {
        var scopes = Set(knownDirectories)
        scopes.formUnion((try? await client.projects())?.compactMap(\.worktree) ?? [])
        let owned = try await listSessions()
        var merged: [String: AgentSession] = [:]
        for session in owned {
            merged[session.id] = session
            await directories.record(sessionID: session.id, directory: session.directory)
        }
        let ordered = Array(scopes)
        for start in stride(from: 0, to: ordered.count, by: 6) {
            let batch = ordered[start..<min(start + 6, ordered.count)]
            await withTaskGroup(of: (String, [AgentSession]).self) { group in
                for directory in batch {
                    group.addTask {
                        let sessions =
                            (try? await self.client.listSessions(directory: directory)) ?? []
                        return (directory, sessions.map(OpenCodeMapping.session))
                    }
                }
                for await (_, sessions) in group {
                    for session in sessions where merged[session.id] == nil {
                        merged[session.id] = session
                        await directories.record(
                            sessionID: session.id, directory: session.directory)
                    }
                }
            }
        }
        return merged.values.filter { !$0.isSubagent }.sorted { $0.updatedAt > $1.updatedAt }
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
        try await OpenCodeMapping.transcript(client.messages(sessionID: sessionID))
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
        try await OpenCodeMapping.transcript(client.messages(sessionID: agentID))
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

    /// The command the setup script leaves on the machine for exactly this, named once so the
    /// client and the installer cannot drift apart on it.
    public static let restartCommand = "opencode-serve-restart"

    public func defaultModel() async throws -> ModelSelection? {
        for provider in try await providers() where provider.defaultModelID != nil {
            return ModelSelection(providerID: provider.id, modelID: provider.defaultModelID!)
        }
        return nil
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Prefer the session's own directory: an unscoped `/event` stream is silent for
                // chats that live outside the server's launch project (e.g. directory=/Users/…),
                // which is exactly what made Linux look frozen while the Mac GPU still worked.
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

    public func runCommand(_ run: CommandRun, in sessionID: String) async throws {
        if run.command.name == "compact" {
            try await dispatchCompaction(run, sessionID: sessionID)
            return
        }
        let directory = await directories.directory(for: sessionID, client: client)
        let request = Self.commandRequest(for: run)
        let client = self.client
        let name = run.command.name
        Task.detached {
            do {
                try await client.runCommand(
                    sessionID: sessionID, directory: directory, request: request)
            } catch {
                AgentLog.logger("opencode").error(
                    "command /\(name) failed: \(error)")
            }
        }
    }

    /// opencode's compaction lives on `/session/:id/summarize`, which blocks until the whole
    /// summarize has finished — so like every command it is dispatched rather than awaited, and the
    /// event stream reports the marker, the summary and the seam. The route needs a model for its
    /// payload: the one the run names when it names one, else the session record's own. opencode's
    /// summarize takes no instructions, so any the preflight collected stay out of the wire; the
    /// server decides what the summary keeps.
    private func dispatchCompaction(_ run: CommandRun, sessionID: String) async throws {
        let payload: (providerID: String, modelID: String)?
        if let model = run.model {
            payload = (model.providerID, model.modelID)
        } else if let session = try? await client.session(sessionID),
            let model = session.model,
            let providerID = model.providerID,
            let modelID = model.id
        {
            payload = (providerID, modelID)
        } else {
            payload = nil
        }
        guard let payload else {
            throw AgentError.unsupported(
                "the server reported no model for this session to summarize with")
        }
        let client = self.client
        Task.detached {
            do {
                try await client.summarize(
                    sessionID: sessionID, providerID: payload.providerID,
                    modelID: payload.modelID)
            } catch {
                AgentLog.logger("opencode").error(
                    "compaction of \(sessionID) failed: \(error)")
            }
        }
    }

    /// The run as opencode's command route wants it. The model is one `providerID/modelID` string
    /// rather than the prompt route's object, the effort travels under opencode's own name for it
    /// (`variant`), and `arguments` is always written — the key is required, and a command with
    /// nothing after it is an empty argument, not an absent one. A command that pins its own model
    /// or agent in its frontmatter still wins on the server, which is right: that pin is the
    /// command author's answer to what may run it, and this asks rather than orders.
    static func commandRequest(for run: CommandRun) -> OCCommandRequest {
        OCCommandRequest(
            command: run.command.name, arguments: run.arguments ?? "",
            model: run.model?.rawValue, agent: run.agent, variant: run.reasoningEffort)
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

    /// opencode embeds attachment bytes straight into the file part's URL as a
    /// data: URI — the server synthesizes `data:<mime>;base64,<bytes>` when a
    /// tool result carries a file — so no bridge round-trip is needed: decode
    /// locally. A `file://` URL (what @-mentioned text files use) is read from
    /// local disk where the path exists, i.e. desktop clients; on iOS it fails
    /// harmlessly and the row falls back to a plain file chip.
    public func attachmentData(_ file: FileReference) async throws -> Data {
        if let url = file.url {
            if let decoded = Self.dataURLBytes(url) { return decoded }
            if url.hasPrefix("file://") {
                let path = String(url.dropFirst("file://".count))
                let decoded = path.removingPercentEncoding ?? path
                if let data = try? Data(contentsOf: URL(fileURLWithPath: decoded)) {
                    return data
                }
            }
        }
        if let path = file.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
        throw AgentError.unsupported("attachment without embedded data")
    }

    static func dataURLBytes(_ url: String) -> Data? {
        guard url.hasPrefix("data:") else { return nil }
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let payload = String(url[url.index(after: comma)...])
        if header.hasSuffix(";base64") {
            let cleaned = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned)
        }
        return Data((payload.removingPercentEncoding ?? payload).utf8)
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

extension OpenCodeBackend: RestartableBackend {
    /// opencode has no restart route — a process cannot be asked to replace itself over its own
    /// API. What it does have is a pty, and the machine has a supervisor, so the restart is run on
    /// the server by the server: one command, the one the setup script leaves behind for exactly
    /// this, reached through the login shell so it does not depend on what PATH a service happened
    /// to inherit.
    ///
    /// Then it is checked, because a restart that quietly did nothing is the one outcome nobody
    /// can act on. A pty outlives the command it ran, so the pty this spawned is still listed by
    /// the process that spawned it — and stops being listed, or stops answering at all, exactly
    /// when that process has gone. A machine with no such command keeps its pty and is told so in
    /// a sentence that says what to do about it.
    public func restart() async throws {
        let pty = try await client.spawn(
            command: "sh", args: ["-lc", Self.restartInvocation], title: "restart")
        for _ in 0..<Self.restartChecks {
            try? await Task.sleep(for: Self.restartCheckInterval)
            guard let ptys = try? await client.ptyIDs() else { return }
            guard ptys.contains(pty) else { return }
        }
        throw AgentError.unsupported(
            "This server was not set up for restarts. Re-run the opencode setup command on that machine."
        )
    }

    static var restartInvocation: String { #"exec "$HOME/.local/bin/\#(restartCommand)""# }
    private static let restartChecks = 10
    private static let restartCheckInterval: Duration = .seconds(1)
}
