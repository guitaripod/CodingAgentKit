import AgentCore
import Foundation

/// opencode 2.x, spoken natively. The API is one namespace under `/api`, a session list that
/// covers every workspace the server holds in one request, a process-wide map of the turns in
/// flight, a transcript stored as records with their content inline, and a single event stream
/// whose frames name the session they belong to — so most of what the 1.x backend had to walk,
/// scope and infer, this one simply asks.
public struct OpenCodeV2Backend: OpenCodeGeneration {
    public let agentType: AgentType = .openCode
    public let capabilities = BackendCapabilities(
        supportsFileBrowsing: true,
        supportsDiffs: true,
        supportsPermissions: true,
        supportsMultipleSessions: true,
        supportsModelSelection: true,
        supportsAttachments: true,
        supportsReasoningEffort: true,
        supportsForking: true,
        supportsAbort: true,
        supportsSessionUsage: true,
        supportsUsageAnalytics: true,
        supportsQuestions: true,
        supportsRenaming: true,
        supportsSubagents: true,
        supportsCommands: true,
        supportsCompaction: true,
        reportsInterruptions: true,
        supportsRevert: true
    )

    let client: OpenCodeV2Client
    let compactions = CompactionWatch()
    let directories = DirectoryCache()
    let local = OpenCodeLocalEvents()
    let cutOffs = CutOffWatch()
    let waitSupport = WaitSupportCache()

    public init(config: ServerConfig) {
        self.client = OpenCodeV2Client(config: config)
    }

    public init(client: OpenCodeV2Client) {
        self.client = client
    }

    /// What each session's last transcript read said about a compaction in flight, so the answer
    /// is free at the moment the conversation asks for it.
    actor CompactionWatch {
        private var startedAt: [String: Date] = [:]

        func record(_ moment: Date?, for sessionID: String) { startedAt[sessionID] = moment }

        func value(for sessionID: String) -> Date? { startedAt[sessionID] }
    }

    /// What each session's last transcript read said about a turn left unfinished, so asking right
    /// after a read costs nothing; a read that is older than a moment is asked afresh.
    actor CutOffWatch {
        private var readings: [String: (turn: TurnInterruption?, at: Date)] = [:]

        func record(_ turn: TurnInterruption?, for sessionID: String) {
            readings[sessionID] = (turn, Date())
        }

        func fresh(for sessionID: String, within: TimeInterval) -> TurnInterruption?? {
            guard let reading = readings[sessionID], Date().timeIntervalSince(reading.at) < within
            else { return nil }
            return .some(reading.turn)
        }
    }

    /// Whether this server answers the experimental wait route at all, found out once by probing
    /// it and remembered for the life of this backend — a server does not gain or lose the route
    /// mid-process, and the probe itself costs a round trip nobody wants to pay per session.
    actor WaitSupportCache {
        private var value: TurnWaitSupport?

        func cached() -> TurnWaitSupport? { value }

        func record(_ support: TurnWaitSupport) { value = support }
    }

    /// Where each session runs, read once off its record: the scoped routes — the command
    /// catalog, the file tree, a local git read — want the workspace the chat lives in.
    actor DirectoryCache {
        private var directories: [String: String] = [:]

        func record(sessionID: String, directory: String?) {
            guard let directory, !directory.isEmpty else { return }
            directories[sessionID] = directory
        }

        func directory(for sessionID: String, client: OpenCodeV2Client) async -> String? {
            if let cached = directories[sessionID] { return cached }
            guard let session = try? await client.session(sessionID),
                let directory = session.location?.directory, !directory.isEmpty
            else { return nil }
            directories[sessionID] = directory
            return directory
        }
    }

    /// How many sessions one listing asks for. The route's own default is the newest fifty,
    /// which is a busy week; a chat list wants the history.
    static let listCeiling = 500

    public func health() async throws -> ServerHealth {
        let info = try await client.info()
        return ServerHealth(healthy: true, version: info.version)
    }

    /// The turns in flight, read once for a whole listing. A map that could not be read leaves
    /// every session's liveness unknown rather than idle.
    private func liveness() async -> Set<String>? {
        guard let active = try? await client.activeSessions() else { return nil }
        return Set(active.filter { OpenCodeV2Mapping.isRunning($0.value) }.map(\.key))
    }

    private func sessions(_ records: [OC2Session], running: Set<String>?) async -> [AgentSession] {
        var agents: [String: Int] = [:]
        if let running {
            for record in records where running.contains(record.id) {
                guard let parent = record.parentID else { continue }
                agents[parent, default: 0] += 1
            }
        }
        var result: [AgentSession] = []
        for record in records {
            await directories.record(sessionID: record.id, directory: record.location?.directory)
            var session = OpenCodeV2Mapping.session(
                record, running: running.map { $0.contains(record.id) })
            session.activeAgents = agents[record.id]
            result.append(session)
        }
        return result
    }

    public func listSessions() async throws -> [AgentSession] {
        let records = try await client.listSessions(limit: Self.listCeiling)
        return await sessions(records, running: liveness())
    }

    /// One request answers for every workspace, so the walk 1.x needed is not needed here. The
    /// agents a conversation spawned are counted onto it and then dropped from the list.
    public func listAllSessions(knownDirectories: [String]) async throws -> [AgentSession] {
        let records = try await client.listSessions(limit: Self.listCeiling)
        return await sessions(records, running: liveness())
            .filter { !$0.isSubagent }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func projects() async throws -> [AgentProject] {
        try await client.projects().compactMap(OpenCodeV2Mapping.project)
    }

    public func listSessions(inWorktree worktree: String?) async throws -> [AgentSession] {
        guard let worktree else { return try await listSessions() }
        let records = try await client.listSessions(limit: Self.listCeiling, directory: worktree)
        return await sessions(records, running: liveness())
    }

    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        var record = try await client.createSession(directory: directory)
        if let title, !title.isEmpty {
            try await client.rename(record.id, title: title)
            record = (try? await client.session(record.id)) ?? record
        }
        await directories.record(sessionID: record.id, directory: record.location?.directory)
        return OpenCodeV2Mapping.session(record, running: false)
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await client.deleteSession(sessionID)
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        try await client.rename(sessionID, title: title)
    }

    public func forkSession(_ sessionID: String) async throws -> AgentSession {
        let record = try await client.fork(sessionID)
        await directories.record(sessionID: record.id, directory: record.location?.directory)
        return OpenCodeV2Mapping.session(record, running: false)
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await transcript(for: sessionID).messages
    }

    public func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        async let record = try? client.session(sessionID)
        let records = try await client.messages(sessionID: sessionID)
        await compactions.record(OpenCodeV2Mapping.compactionInFlight(records), for: sessionID)
        let running = await liveness()
        let session = await record
        let isRunning = running.map { $0.contains(sessionID) }
        await cutOffs.record(
            await settled(Self.cutOff(records, session: session, running: isRunning), sessionID),
            for: sessionID)
        return TranscriptSnapshot(
            messages: OpenCodeV2Mapping.transcript(records),
            status: isRunning.map { $0 ? .running : .idle },
            retry: isRunning == true ? OpenCodeV2Mapping.pendingRetry(records) : nil,
            revert: session?.revert.map(OpenCodeV2Mapping.revert))
    }

    /// A turn is only cut off when nothing on this server is running it and it has been silent
    /// long enough that no other process is writing it either. A managed server picks such a turn
    /// back up by itself when it starts, and that first moment of a restart is inside the quiet.
    static func cutOff(_ records: [OC2Message], session: OC2Session?, running: Bool?)
        -> TurnInterruption?
    {
        guard running == false else { return nil }
        let now = Date()
        guard now.timeIntervalSince(OpenCodeV2Mapping.lastWritten(records, session: session))
            >= orphanQuiet
        else { return nil }
        return OpenCodeV2Mapping.cutOffTurn(records, detectedAt: now)
    }

    static let orphanQuiet: TimeInterval = 120

    public func interruption(for sessionID: String) async throws -> TurnInterruption? {
        if let held = await cutOffs.fresh(for: sessionID, within: 5) { return held }
        async let record = try? client.session(sessionID)
        let records = try await client.messages(sessionID: sessionID)
        let running = try await client.activeSessions()
        let turn = await settled(
            Self.cutOff(
                records, session: await record,
                running: running[sessionID].map(OpenCodeV2Mapping.isRunning) ?? false),
            sessionID)
        await cutOffs.record(turn, for: sessionID)
        return turn
    }

    /// A cut-off turn somebody already let go is not an offer any more. The line saying so waits in
    /// the session's inbox until the next turn delivers it, so the inbox is asked, though only when
    /// the records say a turn was cut off, which is rare, rather than on every read.
    private func settled(_ turn: TurnInterruption?, _ sessionID: String) async -> TurnInterruption? {
        guard let turn else { return nil }
        guard let waiting = try? await client.inbox(sessionID: sessionID) else { return turn }
        return waiting.contains(where: OpenCodeV2Mapping.isDismissal) ? nil : turn
    }

    /// Picks a cut-off turn back up the way opencode's own restart does: a line that tells the
    /// model the server restarted and to carry on without repeating what is done, written into the
    /// session with the turn woken to act on it.
    public func resumeInterruption(sessionID: String) async throws {
        try await client.synthetic(
            sessionID: sessionID,
            request: OC2SyntheticRequest(
                text: Self.resumeText, description: OpenCodeV2Mapping.restartDescription,
                metadata: nil, resume: true))
        await cutOffs.record(nil, for: sessionID)
    }

    /// Lets a cut-off turn go. The line it writes is for the model, so the next turn knows the
    /// last one stopped short, and it settles the turn for every device without waking anything.
    public func dismissInterruption(sessionID: String) async throws {
        try await client.synthetic(
            sessionID: sessionID,
            request: OC2SyntheticRequest(
                text: Self.dismissText, description: nil,
                metadata: .object([
                    OpenCodeV2Mapping.dismissalKey: .string(OpenCodeV2Mapping.dismissalValue)
                ]),
                resume: false))
        await cutOffs.record(nil, for: sessionID)
    }

    static let resumeText =
        "The server restarted while you were working. Continue from where you left off without repeating completed work."
    static let dismissText =
        "The previous turn stopped when the server restarted, and the user chose not to continue it. Do not resume that work unless asked."

    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? {
        let record = try await client.session(sessionID)
        let tokens = OpenCodeV2Mapping.usage(record.tokens)
        guard record.cost != nil || tokens != nil else { return nil }
        return AgentUsage(costUSD: record.cost, tokens: tokens.map(\.total))
    }

    public func revert(sessionID: String, to messageID: String) async throws -> SessionRevert {
        OpenCodeV2Mapping.revert(try await client.stageRevert(sessionID: sessionID, messageID: messageID))
    }

    public func restoreRevert(sessionID: String) async throws {
        try await client.clearRevert(sessionID: sessionID)
    }

    public func revision(for sessionID: String) async throws -> SessionRevision? {
        async let running = liveness()
        let record = try await client.session(sessionID)
        await directories.record(sessionID: record.id, directory: record.location?.directory)
        return SessionRevision(
            updatedAt: OpenCodeV2Mapping.updatedAt(record),
            running: await running.map { $0.contains(sessionID) })
    }

    public func runningCompaction(for sessionID: String) async throws -> CompactionActivity? {
        await compactions.value(for: sessionID).map { CompactionActivity(startedAt: $0) }
    }

    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        let children = try await client.listSessions(limit: Self.listCeiling, parentID: sessionID)
        let running = await liveness() ?? []
        return children
            .map { OpenCodeV2Mapping.subagent($0, running: running.contains($0.id)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        OpenCodeV2Mapping.transcript(try await client.messages(sessionID: agentID))
    }

    /// The model and the agent are standing settings on the session rather than fields on the
    /// prompt, so a prompt that names them sets them first. The effort travels as the model's
    /// variant.
    private func applySelection(
        model: ModelSelection?, effort: String?, agent: String?, to sessionID: String
    ) async throws {
        if let model {
            try await client.switchModel(
                sessionID: sessionID,
                model: OC2ModelRefInput(
                    id: model.modelID, providerID: model.providerID, variant: effort))
        }
        if let agent, !agent.isEmpty {
            try await client.switchAgent(sessionID: sessionID, agent: agent)
        }
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        try await applySelection(
            model: prompt.model, effort: prompt.reasoningEffort, agent: prompt.agent, to: sessionID)
        let files = prompt.attachments.compactMap { attachment -> OC2FileAttachment? in
            guard let uri = Self.attachmentURL(attachment) else { return nil }
            return OC2FileAttachment(uri: uri, name: attachment.filename)
        }
        try await client.prompt(
            sessionID: sessionID,
            request: OC2PromptRequest(text: prompt.text, files: files.isEmpty ? nil : files))
    }

    private static func attachmentURL(_ attachment: PromptAttachment) -> String? {
        if let url = attachment.url { return url }
        if let data = attachment.data {
            return "data:\(attachment.mime);base64,\(data.base64EncodedString())"
        }
        return nil
    }

    public func abort(sessionID: String) async throws {
        try await client.interrupt(sessionID: sessionID)
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let token = await local.listen(sessionID, continuation)
                defer { Task { await self.local.drop(sessionID, token) } }
                var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
                do {
                    for try await sse in client.eventStream() {
                        for event in decoder.decode(sse) {
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

    public func availableCommands(directory: String?) async throws -> [AgentCommand] {
        let published = try await client.commands(directory: directory).map(OpenCodeV2Mapping.command)
        let claimed = Set(published.map(\.name))
        return published + OpenCodeCommon.builtins.filter { !claimed.contains($0.name) }
    }

    public var resolvesCommandsFromPromptText: Bool { false }

    /// A compaction is admitted to the session's inbox and answered at once, so it is awaited and
    /// a refusal reaches the caller as its own error. A command is a turn: it is dispatched like a
    /// prompt and the stream reports what became of it, and a dispatch that fails says so on the
    /// session's own stream, because a command that never ran has no other reply channel.
    public func runCommand(_ run: CommandRun, in sessionID: String) async throws {
        try await applySelection(
            model: run.model, effort: run.reasoningEffort, agent: run.agent, to: sessionID)
        if OpenCodeCommon.isCompaction(run.command.name) {
            try await client.compact(sessionID: sessionID)
            return
        }
        let request = OC2CommandRequest(name: run.command.name, text: run.arguments ?? "")
        let client = self.client
        let local = self.local
        let name = run.command.name
        Task.detached {
            do {
                try await client.command(sessionID: sessionID, request: request)
            } catch {
                AgentLog.logger("opencode2").error("command /\(name) failed: \(error)")
                await local.send(
                    .failure(
                        BackendFailure(
                            message: "/\(name) didn't run.", retryable: true, detail: "\(error)")),
                    to: sessionID)
            }
        }
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await client.replyPermission(
            sessionID: permission.sessionID, requestID: permission.id,
            decision: decision.rawValue)
    }

    /// The form is read back before it is answered: the answer is written in the form's own
    /// keys and values, which the question a client holds does not carry.
    private func form(_ request: QuestionRequest) async throws -> OC2Form {
        let forms = try await client.pendingForms(sessionID: request.sessionID)
        guard let form = forms.first(where: { $0.id == request.id }) else {
            throw AgentError.server("That question is no longer waiting for an answer.")
        }
        return form
    }

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        let form = try await form(request)
        try await client.replyForm(
            sessionID: request.sessionID, formID: request.id,
            answer: OpenCodeV2Mapping.formAnswer(form, answers: answers))
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        try await client.cancelForm(sessionID: request.sessionID, formID: request.id)
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] {
        try await client.pendingForms(sessionID: sessionID).compactMap(OpenCodeV2Mapping.question)
    }

    /// opencode 2 answers every file route relative to a location, and its reader takes the path as
    /// URL segments, so a leading slash is lost. An absolute path is therefore asked of the root
    /// location, which reads it as written and lists entries that are absolute once rooted again.
    private static let rootLocation = "/"

    public func listFiles(path: String?) async throws -> [FileNode] {
        let requested = path ?? "."
        guard requested.hasPrefix("/") else {
            return try await client.files(path: requested, directory: nil).map { OpenCodeV2Mapping.fileNode($0) }
        }
        return try await client.files(path: requested, directory: Self.rootLocation).map {
            OpenCodeV2Mapping.fileNode($0, root: Self.rootLocation)
        }
    }

    public func fileContent(path: String) async throws -> String {
        let bytes = try await client.fileBytes(
            path: path, directory: path.hasPrefix("/") ? Self.rootLocation : nil)
        return String(decoding: bytes, as: UTF8.self)
    }

    public func attachmentData(_ file: FileReference) async throws -> Data {
        try OpenCodeCommon.attachmentData(file)
    }

    public func diff(sessionID: String) async throws -> [FileDiff] {
        try await client.diff(sessionID: sessionID).map(OpenCodeV2Mapping.fileDiff)
    }

    public func find(pattern: String) async throws -> [String] {
        try await client.find(query: pattern, directory: nil).map(\.path)
    }

    public func providers() async throws -> [Provider] {
        async let named = client.providers()
        async let fallback = client.defaultModel()
        let models = try await client.models().filter { $0.enabled ?? true }
        let names = Dictionary(
            (try? await named)?.map { ($0.id, $0.name ?? $0.id) } ?? [], uniquingKeysWith: { a, _ in a })
        let preferred = try? await fallback
        let grouped = Dictionary(grouping: models, by: \.providerID)
        return grouped.keys.sorted().map { providerID in
            let rows = (grouped[providerID] ?? []).map(OpenCodeV2Mapping.modelInfo)
                .sorted { $0.id < $1.id }
            return Provider(
                id: providerID,
                name: names[providerID] ?? providerID,
                models: rows,
                defaultModelID: preferred?.providerID == providerID
                    ? (preferred?.modelID ?? preferred?.id) : nil)
        }
    }

    public func availableModels() async throws -> [ModelInfo] {
        try await providers().flatMap(\.models)
    }

    public func defaultModel() async throws -> ModelSelection? {
        try await client.defaultModel().map(OpenCodeV2Mapping.modelSelection)
    }

    /// The agents a person can send a prompt as: the primary ones the server does not hide.
    public func availableAgents() async throws -> [String] {
        try await client.agents()
            .filter { $0.hidden != true && ($0.mode ?? "primary") != "subagent" }
            .map(\.id)
    }

    public func usageAnalytics(days: Int) async throws -> UsageAnalyticsReport? {
        let records = try await client.listSessions(limit: OpenCodeLedger.sessionCeiling)
        return OpenCodeLedger.report(records: records.map(OpenCodeLedger.Record.init), days: days)
    }
}

/// `POST /api/experimental/session/:id/wait` — new in 2.x, marked experimental and carrying no
/// backward-compat guarantee, so support is found out from the machine rather than assumed from
/// the generation: a session id that cannot exist tells the route apart from an old server's
/// catch-all, which answers an unmatched path with its own bundled web UI rather than a 404.
extension OpenCodeV2Backend {
    /// How many of the newest records the outcome is read from — enough to hold a turn's own
    /// prompt, its steps and its answer without walking a long conversation's whole history.
    static let waitTailLimit = 60

    public func turnWaitRequest(for sessionID: String) async throws -> TurnWaitRequest? {
        guard await turnWaitSupport() == .supported else { return nil }
        return TurnWaitRequest(
            request: try client.builder.request(
                .post, "/api/experimental/session/\(sessionID)/wait"),
            uploadsEmptyBody: true)
    }

    public func turnWaitSupport() async -> TurnWaitSupport {
        if let cached = await waitSupport.cached() { return cached }
        let probed = await probeWaitSupport()
        if probed == .supported || probed == .serverTooOld {
            await waitSupport.record(probed)
        }
        return probed
    }

    /// Asks the route itself, on a session id built so it cannot collide with a real one: the
    /// route answering a typed `404` about that missing session proves the route exists; an
    /// unmatched path on this same server answers `200` with the bundled web UI's HTML instead.
    /// Anything else — a refused connection, an auth challenge — is asked again next time rather
    /// than remembered as either.
    private func probeWaitSupport() async -> TurnWaitSupport {
        let probeID = "turnwait-probe-\(UUID().uuidString)"
        guard let raw = try? await client.rawWait(sessionID: probeID) else { return .serverTooOld }
        return Self.classifyWaitProbe(raw)
    }

    static func classifyWaitProbe(_ raw: HTTPClient.RawResponse) -> TurnWaitSupport {
        guard raw.status == 404 else { return .serverTooOld }
        let contentType = (raw.headers["Content-Type"] ?? raw.headers["content-type"] ?? "")
            .lowercased()
        guard !contentType.contains("html") else { return .serverTooOld }
        guard (try? JSONSerialization.jsonObject(with: raw.data)) != nil else { return .serverTooOld }
        return .supported
    }

    /// Only a `204` means the agent loop went idle — any other status is a shape this backend has
    /// no reading for, including opencode's own `503` for a wait that outlived its own budget, and
    /// is thrown rather than guessed at. A pending form or permission outranks the transcript: the
    /// loop can be idle *because* it is waiting on the person, and that is `needsYou`, not `ended`.
    public func turnWaitResult(
        status: Int, headers: [String: String], body: Data, sessionID: String
    ) async throws -> TurnWaitResult {
        guard status == 204 else {
            throw AgentError.http(status: status, body: String(data: body, encoding: .utf8) ?? "")
        }
        if let forms = try? await client.pendingForms(sessionID: sessionID), !forms.isEmpty {
            return TurnWaitResult(state: .needsYou, waited: true, ending: .question)
        }
        if let permissions = try? await client.pendingPermissions(sessionID: sessionID),
            !permissions.isEmpty
        {
            return TurnWaitResult(state: .needsYou, waited: true, ending: .approval)
        }
        let tail = (try? await client.recentMessages(sessionID: sessionID, limit: Self.waitTailLimit))
            ?? []
        guard let outcome = OpenCodeV2Mapping.waitOutcome(tail: OpenCodeV2Mapping.transcript(tail))
        else {
            return TurnWaitResult(state: .ended, waited: true, ending: .finished)
        }
        let title = try? await client.session(sessionID).title
        return TurnWaitResult(
            state: .ended, waited: true, ending: outcome.ending, title: title,
            toolCount: outcome.toolCount, lastMessageID: outcome.lastMessageID)
    }
}

extension OpenCodeLedger.Record {
    init(_ session: OC2Session) {
        self.init(
            id: session.id,
            title: session.title,
            parentID: session.parentID,
            directory: session.location?.directory,
            lastActive: OpenCodeV2Mapping.updatedAt(session),
            cost: session.cost,
            tokens: OpenCodeLedger.Tokens(
                input: Int(session.tokens?.input ?? 0),
                output: Int(session.tokens?.output ?? 0),
                reasoning: Int(session.tokens?.reasoning ?? 0),
                cacheRead: Int(session.tokens?.cache?.read ?? 0),
                cacheWrite: Int(session.tokens?.cache?.write ?? 0)),
            modelID: session.model?.id,
            providerID: session.model?.providerID)
    }
}

extension OpenCodeV2Backend: RestartableBackend {
    public func restart() async throws {
        try await OpenCodeCommon.restart(spawn: spawn, ptyIDs: ptyIDs)
    }

    var spawn: OpenCodeCommon.Spawn {
        let client = self.client
        return { command, args, _ in try await client.spawn(command: command, args: args) }
    }

    var ptyIDs: OpenCodeCommon.PtyIDs {
        let client = self.client
        return { try await client.ptyIDs() }
    }
}

extension OpenCodeV2Backend: ServeManagerBackend {
    public func installServeManager() async throws {
        try await OpenCodeCommon.installServeManager(spawn: spawn, ptyIDs: ptyIDs)
    }
}

/// opencode has no `/git` routes. When the conversation's directory is a path this process can
/// open — the desktop client sitting next to the checkout — the repository is read locally. A
/// remote phone talking to a remote opencode has no path here, so the band stays quiet about git
/// rather than inventing a failure.
extension OpenCodeV2Backend: GitObservingBackend {
    public func gitSnapshot(directory: String?, sessionID: String?) async throws -> GitSnapshot? {
        guard let directory = await resolveGitDirectory(directory, sessionID: sessionID)
        else { return nil }
        #if os(macOS) || os(Linux)
            return await Task.detached(priority: .utility) {
                LocalGit.snapshot(directory: directory)
            }.value
        #else
            return nil
        #endif
    }

    public func gitPatch(directory: String?, sessionID: String?, path: String, staged: Bool)
        async throws -> GitPatch?
    {
        guard let directory = await resolveGitDirectory(directory, sessionID: sessionID)
        else { return nil }
        #if os(macOS) || os(Linux)
            return await Task.detached(priority: .utility) {
                LocalGit.patch(directory: directory, path: path, staged: staged)
            }.value
        #else
            return nil
        #endif
    }

    public func gitCommit(directory: String?, sessionID: String?, hash: String) async throws
        -> GitCommitDetail?
    {
        guard let directory = await resolveGitDirectory(directory, sessionID: sessionID)
        else { return nil }
        #if os(macOS) || os(Linux)
            return await Task.detached(priority: .utility) {
                LocalGit.commit(directory: directory, hash: hash)
            }.value
        #else
            return nil
        #endif
    }

    private func resolveGitDirectory(_ directory: String?, sessionID: String?) async -> String? {
        if let directory, !directory.isEmpty, FileManager.default.fileExists(atPath: directory) {
            return directory
        }
        guard let sessionID, !sessionID.isEmpty,
            let resolved = await directories.directory(for: sessionID, client: client),
            FileManager.default.fileExists(atPath: resolved)
        else { return nil }
        return resolved
    }
}

/// The chat list, pushed rather than polled. opencode 2's one stream carries every session's
/// transitions with the session named on each frame: a turn opening and closing, a title
/// arriving, a session made or deleted.
extension OpenCodeV2Backend: SessionListStreaming {
    public func sessionListChanges() async -> AsyncStream<SessionListChange>? {
        AsyncStream { continuation in
            let task = Task {
                let memory = OpenCodeListMemory()
                while !Task.isCancelled {
                    continuation.yield(.invalidated)
                    do {
                        for try await sse in client.eventStream() {
                            if Task.isCancelled { return }
                            for change in await self.changes(from: sse, memory: memory) {
                                continuation.yield(change)
                            }
                        }
                    } catch {
                        AgentLog.logger("opencode2").debug("event stream ended: \(error)")
                    }
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func changes(from event: SSEvent, memory: OpenCodeListMemory) async
        -> [SessionListChange]
    {
        guard let frame = OpenCodeV2EventDecoder.frame(event),
            let sessionID = frame.data?["sessionID"]?.stringValue
        else { return [] }

        switch frame.type {
        case "session.created", "session.renamed", "session.model.selected", "session.agent.selected",
            "session.forked":
            guard let record = try? await client.session(sessionID) else { return [] }
            await directories.record(sessionID: record.id, directory: record.location?.directory)
            let fresh = OpenCodeV2Mapping.session(record, running: nil)
            let merged = await memory.adopting(fresh)
            let changed = await memory.differs(merged)
            await memory.remember(merged)
            guard changed, !merged.isSubagent else { return [] }
            return [.upsert(merged)]

        case "session.deleted":
            await memory.forget(sessionID)
            return [.remove(sessionID)]

        case "session.execution.started", "session.execution.succeeded",
            "session.execution.failed", "session.execution.interrupted", "session.idle",
            "session.status":
            let running: Bool
            switch frame.type {
            case "session.execution.started": running = true
            case "session.status":
                running = (frame.data?["status"]?["type"]?.stringValue).map(
                    OpenCodeV2Mapping.isRunning) ?? false
            default: running = false
            }
            if await memory.session(sessionID) == nil {
                guard let record = try? await client.session(sessionID) else { return [] }
                await memory.remember(OpenCodeV2Mapping.session(record, running: nil))
            }
            return await memory.setRunning(running, for: sessionID)
                .filter { !$0.isSubagent }
                .map { .upsert($0) }

        default:
            return []
        }
    }
}
