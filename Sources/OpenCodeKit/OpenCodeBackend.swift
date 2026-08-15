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
    let directories = SessionDirectoryCache()
    let compactions = CompactionWatch()

    public init(config: ServerConfig) {
        self.client = OpenCodeClient(config: config)
    }

    public init(client: OpenCodeClient) {
        self.client = client
    }

    /// What each session's last transcript read said about a compaction in flight, so the answer
    /// is free at the moment the conversation asks for it.
    actor CompactionWatch {
        private var startedAt: [String: Date] = [:]

        func record(_ moment: Date?, for sessionID: String) { startedAt[sessionID] = moment }

        func value(for sessionID: String) -> Date? { startedAt[sessionID] }
    }

    /// opencode scopes `/event` and `/question` by workspace directory, so
    /// per-session calls need the session's directory. Cached; refreshed from
    /// the session list on miss — and from `GET /session/:id` when the session
    /// lives outside every known project (home-directory chats, for example).
    actor SessionDirectoryCache {
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

    /// The events this Kit raises itself, put on the session's own stream so a client reads them
    /// exactly like the server's.
    ///
    /// opencode answers a command only once the turn it started has ended, so a command is
    /// dispatched rather than awaited — and a dispatch that fails then has no reply channel at all.
    /// A compaction that never started used to be a line in a log file: the preflight closed, the
    /// spinner stopped and the transcript sat exactly as it was, which reads as the app ignoring
    /// the request. It says so here instead.
    actor LocalEvents {
        private var listeners:
            [String: [UUID: AsyncThrowingStream<BackendEvent, Error>.Continuation]] = [:]

        func listen(
            _ sessionID: String,
            _ continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation
        ) -> UUID {
            let token = UUID()
            listeners[sessionID, default: [:]][token] = continuation
            return token
        }

        func drop(_ sessionID: String, _ token: UUID) {
            listeners[sessionID]?.removeValue(forKey: token)
            if listeners[sessionID]?.isEmpty == true { listeners[sessionID] = nil }
        }

        func send(_ event: BackendEvent, to sessionID: String) {
            guard let slots = listeners[sessionID] else { return }
            for continuation in slots.values { continuation.yield(event) }
        }
    }

    let local = LocalEvents()

    public func health() async throws -> ServerHealth {
        let health = try await client.health()
        return ServerHealth(healthy: health.healthy, version: health.version)
    }

    /// What the server said about turns in flight, and — just as importantly — which workspaces it
    /// was actually asked about.
    ///
    /// `/session/status` is scoped to one directory, so a chat's answer only exists in the map its
    /// own directory returned. A scope that was never asked, or that failed, leaves its sessions
    /// *unknown* rather than idle: a listing that cannot see a turn must not report there is none.
    struct LivenessReading: Sendable {
        var running: Set<String> = []
        var scopes: Set<String> = []

        var isEmpty: Bool { scopes.isEmpty }

        mutating func absorb(_ statuses: [String: OCSessionStatus], scope: String) {
            scopes.insert(scope)
            for (id, status) in statuses where OpenCodeMapping.isRunning(status) {
                running.insert(id)
            }
        }

        /// The workspace a session's liveness would be reported under. The server's own launch
        /// directory answers the unscoped ask, which is what a session with no directory rides.
        static func scope(of directory: String?) -> String { directory ?? "" }
    }

    /// One `/session/status` per distinct workspace, asked in the same small batches the directory
    /// walk uses so a machine with thirty projects does not open thirty sockets at once. A scope
    /// that throws is simply left out of the reading, so its sessions keep saying nothing rather
    /// than saying idle.
    func liveness(scopes: Set<String>) async -> LivenessReading {
        var reading = LivenessReading()
        guard !scopes.isEmpty else { return reading }
        let client = self.client
        let ordered = Array(scopes)
        for start in stride(from: 0, to: ordered.count, by: 6) {
            let batch = ordered[start..<min(start + 6, ordered.count)]
            let answers = await withTaskGroup(
                of: (String, [String: OCSessionStatus]?).self
            ) { group -> [(String, [String: OCSessionStatus]?)] in
                for scope in batch {
                    group.addTask {
                        let statuses = try? await client.sessionStatuses(
                            directory: scope.isEmpty ? nil : scope)
                        return (scope, statuses)
                    }
                }
                var collected: [(String, [String: OCSessionStatus]?)] = []
                for await answer in group { collected.append(answer) }
                return collected
            }
            for (scope, statuses) in answers {
                guard let statuses else { continue }
                reading.absorb(statuses, scope: scope)
            }
        }
        return reading
    }

    /// The listing's own answer about which conversations have a turn open, written onto the
    /// sessions it describes. A parent whose own turn is closed while the agents it spawned still
    /// run is working, so the busy children are counted onto it rather than lost with them.
    static func applying(
        _ reading: LivenessReading, to sessions: [AgentSession]
    ) -> [AgentSession] {
        guard !reading.isEmpty else { return sessions }
        var agents: [String: Int] = [:]
        for session in sessions where reading.running.contains(session.id) {
            guard let parent = session.parentID else { continue }
            agents[parent, default: 0] += 1
        }
        return sessions.map { session in
            var session = session
            let scope = LivenessReading.scope(of: session.directory)
            if reading.scopes.contains(scope) {
                session.isActive = reading.running.contains(session.id)
            }
            session.activeAgents = agents[session.id]
            return session
        }
    }

    private static func scopes(of sessions: [AgentSession]) -> Set<String> {
        Set(sessions.map { LivenessReading.scope(of: $0.directory) })
    }

    public func listSessions() async throws -> [AgentSession] {
        let sessions = try await client.listSessions().map { OpenCodeMapping.session($0) }
        return Self.applying(await liveness(scopes: Self.scopes(of: sessions)), to: sessions)
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
    /// the only chat the work produced. The turns in flight are written on before that drop, so a
    /// parent still collects the agents working for it rather than losing the count with them.
    public func listAllSessions(knownDirectories: [String]) async throws -> [AgentSession] {
        var scopes = Set(knownDirectories)
        scopes.formUnion((try? await client.projects())?.compactMap(\.worktree) ?? [])
        let owned = try await client.listSessions().map { OpenCodeMapping.session($0) }
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
                        return (directory, sessions.map { OpenCodeMapping.session($0) })
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
        let sessions = Array(merged.values)
        let reading = await liveness(scopes: Self.scopes(of: sessions).union(scopes))
        return Self.applying(reading, to: sessions)
            .filter { !$0.isSubagent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func projects() async throws -> [AgentProject] {
        try await client.projects().compactMap(OpenCodeMapping.project)
    }

    public func listSessions(inWorktree worktree: String?) async throws -> [AgentSession] {
        guard let worktree else { return try await listSessions() }
        let sessions = try await client.listSessions(directory: worktree)
            .map { OpenCodeMapping.session($0) }
        let reading = await liveness(
            scopes: Self.scopes(of: sessions).union([worktree]))
        return Self.applying(reading, to: sessions)
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
        let envelopes = try await client.messages(sessionID: sessionID)
        await compactions.record(
            OpenCodeMapping.compactionInFlight(envelopes), for: sessionID)
        return OpenCodeMapping.transcript(envelopes)
    }

    /// What the last read of this session's transcript said about a compaction still running. The
    /// transcript is the authority — a dangling marker is `summarize` in flight — and it is read
    /// here rather than fetched again, because the caller asks this immediately after a transcript
    /// load and a second pass over a long conversation's messages is a round trip for a fact we
    /// just had in hand.
    public func runningCompaction(for sessionID: String) async throws -> CompactionActivity? {
        await compactions.value(for: sessionID).map { CompactionActivity(startedAt: $0) }
    }

    /// opencode gives a spawned agent a session of its own, parented to the one
    /// that spawned it. Those children are subagents, not conversations: they
    /// are reported here so a client can nest them under their parent rather
    /// than list them as chats in their own right.
    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        let sessions: [OCSession]
        let directory = await directories.directory(for: sessionID, client: client)
        if let directory {
            sessions = (try? await client.listSessions(directory: directory)) ?? []
        } else {
            sessions = (try? await client.listSessions()) ?? []
        }
        let scope = LivenessReading.scope(of: directory)
        let reading = await liveness(scopes: [scope])
        let running = reading.scopes.contains(scope) ? reading.running : nil
        return sessions
            .filter { $0.parentID == sessionID }
            .map { OpenCodeMapping.subagent($0, running: running) }
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
                let token = await local.listen(sessionID, continuation)
                defer { Task { await self.local.drop(sessionID, token) } }
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

    /// What this session can be told to do: the server's own catalog for the chat's directory —
    /// user and project command files, MCP prompts, and skills, and the project half of that only
    /// exists for a request that names the directory — plus the built-ins the Kit runs itself.
    ///
    /// `GET /command` answers with prompt templates only; its schema requires a `template`, so the
    /// slash words opencode's own client offers for its built-in actions are structurally absent
    /// from it. A command nobody can see is a command nobody has, so the ones this Kit can carry
    /// out are published beside the server's. The server wins any collision: a `compact.md` written
    /// by hand is that machine's answer to what the word means.
    public func availableCommands(directory: String?) async throws -> [AgentCommand] {
        let published = try await client.commands(directory: directory).map(Self.command)
        let claimed = Set(published.map(\.name))
        return published + Self.builtins.filter { !claimed.contains($0.name) }
    }

    /// The built-in slash words this Kit can execute for an opencode server. `compact` carries no
    /// argument hint because `supportsCompactionInstructions` is false here — the server decides
    /// what its summary keeps, and promising a place to say otherwise would be a lie.
    static let builtins: [AgentCommand] = [
        AgentCommand(
            name: "compact",
            details: "Summarize the conversation so far to free up context",
            argumentHint: nil,
            source: .builtin)
    ]

    /// opencode publishes `summarize` as `compact`'s own alias, so both spellings reach the same
    /// route rather than one of them going out to the model as the word it was typed as.
    static func isCompaction(_ name: String) -> Bool {
        name == "compact" || name == "summarize"
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
        if Self.isCompaction(run.command.name) {
            try await dispatchCompaction(run, sessionID: sessionID)
            return
        }
        let directory = await directories.directory(for: sessionID, client: client)
        let request = Self.commandRequest(for: run)
        let client = self.client
        let name = run.command.name
        let local = self.local
        Task.detached {
            do {
                try await client.runCommand(
                    sessionID: sessionID, directory: directory, request: request)
            } catch {
                AgentLog.logger("opencode").error(
                    "command /\(name) failed: \(error)")
                await local.send(
                    .failure(
                        BackendFailure(
                            message: "/\(name) didn't run.",
                            retryable: true, detail: "\(error)")),
                    to: sessionID)
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
        let local = self.local
        let directory = await directories.directory(for: sessionID, client: client)
        Task.detached {
            do {
                try await client.summarize(
                    sessionID: sessionID, directory: directory, providerID: payload.providerID,
                    modelID: payload.modelID)
            } catch {
                AgentLog.logger("opencode").error(
                    "compaction of \(sessionID) failed: \(error)")
                await local.send(
                    .compaction(
                        CompactionActivity(
                            startedAt: Date(), failure: CompactionActivity.unexplainedFailure)),
                    to: sessionID)
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
        guard try await Self.restartWorks(client: client) else {
            throw AgentError.unsupported(
                "This server was not set up for restarts. Re-run the opencode setup command on that machine."
            )
        }
    }

    static var restartInvocation: String { #"exec "$HOME/.local/bin/\#(restartCommand)""# }
    private static let restartChecks = 10
    private static let restartCheckInterval: Duration = .seconds(1)

    /// Spawns the restart and watches for this process's ptys to go with it. A `nil` answer is a
    /// server that just restarted — the ask provably took.
    private static func restartWorks(client: OpenCodeClient) async throws -> Bool {
        let pty = try await client.spawn(
            command: "sh", args: ["-lc", restartInvocation], title: "restart")
        for _ in 0..<restartChecks {
            try? await Task.sleep(for: restartCheckInterval)
            guard let ptys = try? await client.ptyIDs() else { return true }
            guard ptys.contains(pty) else { return true }
        }
        return false
    }
}

extension OpenCodeBackend: ServeManagerBackend {
    /// The whole setup, run on the machine by the machine: opencode if it is missing, the
    /// supervisor that survives a reboot, the restart command, and the check that restarts the
    /// server when its model list changes. The installer may replace the very process answering
    /// this ask — a machine whose own supervisor takes the port boots the hand-run server out — so
    /// the answer is read from the machine after, not awaited in flight: once it answers and
    /// provably restarts, the setup has taken.
    public func installServeManager() async throws {
        _ = try await client.spawn(
            command: "sh", args: ["-lc", Self.installInvocation], title: "set up server")
        for _ in 0..<Self.installChecks {
            try? await Task.sleep(for: Self.installCheckInterval)
            guard (try? await client.ptyIDs()) != nil else { continue }
            if try await Self.restartWorks(client: client) { return }
            break
        }
        throw AgentError.unsupported(
            "The setup did not take. Run the opencode setup command on that machine by hand.")
    }

    static var installInvocation: String {
        #"curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | bash"#
    }
    private static let installChecks = 60
    private static let installCheckInterval: Duration = .seconds(2)
}
