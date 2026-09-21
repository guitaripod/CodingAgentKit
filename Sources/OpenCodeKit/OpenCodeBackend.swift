import AgentCore
import Foundation

/// An opencode server, whichever generation of its API it speaks.
///
/// opencode 2.0 replaced its whole HTTP surface — every route moved under `/api`, the records
/// changed shape and the events changed name — and a saved server is a saved address, not a
/// saved API. So the generation is found out from the machine rather than from the profile:
/// the first call asks `/api/info`, which only a 2.x server answers, and falls back to
/// `/global/health`, which only a 1.x server answers, and every call after that goes to the
/// backend that speaks what the server spoke. A health check asks again, so a server upgraded
/// under a running client is followed onto its new API without a reconnect.
public struct OpenCodeBackend: FileBrowsingBackend, RestartableBackend, GitObservingBackend,
    ServeManagerBackend, SessionListStreaming
{
    public let agentType: AgentType = .openCode

    /// What the resolved generation can do — until one is resolved, what every opencode can.
    public var capabilities: BackendCapabilities {
        negotiation.capabilities ?? OpenCodeV1Backend.baseline
    }

    /// The command the setup script leaves on the machine for exactly this, named once so the
    /// client and the installer cannot drift apart on it.
    public static let restartCommand = OpenCodeCommon.restartCommand

    let negotiation: OpenCodeNegotiation

    public init(config: ServerConfig) {
        let v1 = OpenCodeV1Backend(config: config)
        let v2 = OpenCodeV2Backend(config: config)
        self.negotiation = OpenCodeNegotiation {
            try await Self.negotiate(v1: v1, v2: v2)
        }
    }

    /// Testing seam: a backend whose generation is decided by `resolve` rather than by a server.
    init(resolve: @escaping @Sendable () async throws -> any OpenCodeGeneration) {
        self.negotiation = OpenCodeNegotiation(resolve: resolve)
    }

    /// Which API the server speaks. A 2.x server answers `/api/info` with its version; a 1.x
    /// server answers that path with a 404 and `/global/health` with its health. A refusal — a
    /// password wanted, a tailnet the device is not on — and a machine that cannot be reached at
    /// all are answers about the connection rather than the generation, and are thrown as they
    /// are so the caller sees the same failure either generation would have shown.
    static func negotiate(v1: OpenCodeV1Backend, v2: OpenCodeV2Backend) async throws
        -> any OpenCodeGeneration
    {
        do {
            _ = try await v2.client.info()
            return v2
        } catch let error as AgentError {
            switch error {
            case .http(let status, _) where status == 401 || status == 403:
                throw error
            case .connection:
                throw error
            default:
                break
            }
        }
        _ = try await v1.client.health()
        return v1
    }

    func resolved() async throws -> any OpenCodeGeneration {
        try await negotiation.generation()
    }

    /// A health check is also a fresh look at the generation, because a server that was 1.x an
    /// hour ago may have been updated since — and its answer is the resolved backend's own.
    public func health() async throws -> ServerHealth {
        try await negotiation.refresh().health()
    }

    public func listSessions() async throws -> [AgentSession] {
        try await resolved().listSessions()
    }

    public func listAllSessions(knownDirectories: [String]) async throws -> [AgentSession] {
        try await resolved().listAllSessions(knownDirectories: knownDirectories)
    }

    public func projects() async throws -> [AgentProject] {
        try await resolved().projects()
    }

    public func listSessions(inWorktree worktree: String?) async throws -> [AgentSession] {
        try await resolved().listSessions(inWorktree: worktree)
    }

    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        try await resolved().createSession(title: title, directory: directory)
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await resolved().deleteSession(sessionID)
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await resolved().messages(for: sessionID)
    }

    public func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        try await resolved().transcript(for: sessionID)
    }

    public func revision(for sessionID: String) async throws -> SessionRevision? {
        try await resolved().revision(for: sessionID)
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        try await resolved().send(prompt, to: sessionID)
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let generation = try await resolved()
                    for try await event in generation.events(for: sessionID) {
                        continuation.yield(event)
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
        try await resolved().abort(sessionID: sessionID)
    }

    public func stopBackgroundWork(sessionID: String) async throws {
        try await resolved().stopBackgroundWork(sessionID: sessionID)
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await resolved().respond(to: permission, decision: decision)
    }

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        try await resolved().answerQuestion(request, answers: answers)
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        try await resolved().rejectQuestion(request)
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] {
        try await resolved().pendingQuestions(for: sessionID)
    }

    public func pendingQuestions(in messages: [ChatMessage], sessionID: String) -> [QuestionRequest] {
        []
    }

    public func attachmentData(_ file: FileReference) async throws -> Data {
        try OpenCodeCommon.attachmentData(file)
    }

    public func availableModels() async throws -> [ModelInfo] {
        try await resolved().availableModels()
    }

    public func availableAgents() async throws -> [String] {
        try await resolved().availableAgents()
    }

    public func defaultModel() async throws -> ModelSelection? {
        try await resolved().defaultModel()
    }

    public var reasoningEffortOptions: [String] { [] }

    public func setReasoningEffort(_ level: String) async throws {
        try await resolved().setReasoningEffort(level)
    }

    public func applyModelSelection(_ model: ModelSelection) async throws {
        try await resolved().applyModelSelection(model)
    }

    public func clearConversation(_ sessionID: String) async throws {
        try await resolved().clearConversation(sessionID)
    }

    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? {
        try await resolved().sessionUsage(sessionID)
    }

    public func sessionSpend(_ sessionID: String) async throws -> SessionSpendReport? {
        try await resolved().sessionSpend(sessionID)
    }

    public func usageAnalytics(days: Int) async throws -> UsageAnalyticsReport? {
        try await resolved().usageAnalytics(days: days)
    }

    public func usageQuota() async throws -> UsageQuota? {
        try await resolved().usageQuota()
    }

    public func registerLiveActivity(_ registration: LiveActivityRegistration, for sessionID: String)
        async throws
    {
        try await resolved().registerLiveActivity(registration, for: sessionID)
    }

    public func registerDeviceToken(_ registration: DevicePushRegistration) async throws {
        try await resolved().registerDeviceToken(registration)
    }

    public func unregisterDeviceToken(_ registration: DevicePushRegistration) async throws {
        try await resolved().unregisterDeviceToken(registration)
    }

    public func additionalUsageQuotas() async throws -> [UsageQuota] {
        try await resolved().additionalUsageQuotas()
    }

    public func forkSession(_ sessionID: String) async throws -> AgentSession {
        try await resolved().forkSession(sessionID)
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        try await resolved().renameSession(sessionID, title: title)
    }

    public func setSessionSaved(_ sessionID: String, saved: Bool) async throws {
        try await resolved().setSessionSaved(sessionID, saved: saved)
    }

    public func availableCommands(directory: String?) async throws -> [AgentCommand] {
        try await resolved().availableCommands(directory: directory)
    }

    public func runCommand(_ run: CommandRun, in sessionID: String) async throws {
        try await resolved().runCommand(run, in: sessionID)
    }

    public var resolvesCommandsFromPromptText: Bool { false }

    public func goal(for sessionID: String) async throws -> SessionGoal? {
        try await resolved().goal(for: sessionID)
    }

    public func interruption(for sessionID: String) async throws -> TurnInterruption? {
        try await resolved().interruption(for: sessionID)
    }

    public func runningCompaction(for sessionID: String) async throws -> CompactionActivity? {
        try await resolved().runningCompaction(for: sessionID)
    }

    public func resumeInterruption(sessionID: String) async throws {
        try await resolved().resumeInterruption(sessionID: sessionID)
    }

    public func dismissInterruption(sessionID: String) async throws {
        try await resolved().dismissInterruption(sessionID: sessionID)
    }

    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        try await resolved().subagents(for: sessionID)
    }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        try await resolved().subagentMessages(sessionID: sessionID, agentID: agentID)
    }

    public func searchTranscripts(_ query: String, limit: Int) async throws -> TranscriptSearchResult {
        try await resolved().searchTranscripts(query, limit: limit)
    }

    public func listFiles(path: String?) async throws -> [FileNode] {
        try await resolved().listFiles(path: path)
    }

    public func fileContent(path: String) async throws -> String {
        try await resolved().fileContent(path: path)
    }

    public func diff(sessionID: String) async throws -> [FileDiff] {
        try await resolved().diff(sessionID: sessionID)
    }

    public func find(pattern: String) async throws -> [String] {
        try await resolved().find(pattern: pattern)
    }

    public func providers() async throws -> [Provider] {
        try await resolved().providers()
    }

    public func restart() async throws {
        try await resolved().restart()
    }

    public func installServeManager() async throws {
        try await resolved().installServeManager()
    }

    public func gitSnapshot(directory: String?, sessionID: String?) async throws -> GitSnapshot? {
        try await resolved().gitSnapshot(directory: directory, sessionID: sessionID)
    }

    public func gitPatch(directory: String?, sessionID: String?, path: String, staged: Bool)
        async throws -> GitPatch?
    {
        try await resolved().gitPatch(
            directory: directory, sessionID: sessionID, path: path, staged: staged)
    }

    public func gitCommit(directory: String?, sessionID: String?, hash: String) async throws
        -> GitCommitDetail?
    {
        try await resolved().gitCommit(directory: directory, sessionID: sessionID, hash: hash)
    }

    /// The list stream waits for the generation rather than answering nil when the server is
    /// away at the moment of asking: a nil here is read as a server with no such stream, which
    /// would leave the list polling for the rest of the process.
    public func sessionListChanges() async -> AsyncStream<SessionListChange>? {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let generation = try? await resolved() {
                        guard let inner = await generation.sessionListChanges() else {
                            continuation.finish()
                            return
                        }
                        for await change in inner {
                            if Task.isCancelled { return }
                            continuation.yield(change)
                        }
                        continuation.finish()
                        return
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// One answer per server about which API it speaks, found out once and shared by every call,
/// refreshed on request, and never remembered when the asking itself failed.
final class OpenCodeNegotiation: Sendable {
    private let resolve: @Sendable () async throws -> any OpenCodeGeneration
    private let state = State()
    private let known = CapabilityBox()

    init(resolve: @escaping @Sendable () async throws -> any OpenCodeGeneration) {
        self.resolve = resolve
    }

    /// The answer, and the one ask in flight for it. A task is made inside the actor so two
    /// callers arriving together share one ask rather than each starting their own.
    private actor State {
        var resolved: (any OpenCodeGeneration)?
        var inFlight: Task<any OpenCodeGeneration, Error>?

        func current() -> (any OpenCodeGeneration)? { resolved }

        func ask(
            _ resolve: @escaping @Sendable () async throws -> any OpenCodeGeneration,
            known: CapabilityBox, fresh: Bool
        ) -> Task<any OpenCodeGeneration, Error> {
            if !fresh, let inFlight { return inFlight }
            let task = Task {
                let generation = try await resolve()
                known.write(generation.capabilities)
                return generation
            }
            inFlight = task
            Task { await self.settle(task) }
            return task
        }

        private func settle(_ task: Task<any OpenCodeGeneration, Error>) async {
            let outcome = try? await task.value
            guard inFlight == task else { return }
            if let outcome { resolved = outcome }
            inFlight = nil
        }
    }

    private final class CapabilityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: BackendCapabilities?

        func read() -> BackendCapabilities? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ capabilities: BackendCapabilities) {
            lock.lock()
            value = capabilities
            lock.unlock()
        }
    }

    var capabilities: BackendCapabilities? { known.read() }

    func generation() async throws -> any OpenCodeGeneration {
        if let resolved = await state.current() { return resolved }
        return try await state.ask(resolve, known: known, fresh: false).value
    }

    /// Asks the machine again whatever is held or in flight; an older ask still settling cannot
    /// overwrite the newer answer, because a settle only lands for the ask it belongs to.
    func refresh() async throws -> any OpenCodeGeneration {
        try await state.ask(resolve, known: known, fresh: true).value
    }
}
