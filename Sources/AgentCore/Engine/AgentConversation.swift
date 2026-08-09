import Foundation

public actor AgentConversation {
    public let backend: any CodingAgentBackend
    public let sessionID: String

    private let policy: ConnectionPolicy
    private let cache: SessionCache?

    private var reducer: MessageReducer
    private var status: BackendStatus = .unknown
    private var pendingPermissions: [PermissionRequest] = []
    private var pendingQuestions: [QuestionRequest] = []
    private var transcriptQuestions: [QuestionRequest] = []
    private var resolvedQuestionIDs: Set<String> = []
    private var lastFailure: BackendFailure?
    private var connection: ConnectionPhase = .connecting
    private var loadedTranscript = false
    private var goal: SessionGoal?
    private var compaction: CompactionActivity?

    private var streamTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var lastStreamPersist = Date.distantPast
    private var subscribers: [UUID: AsyncStream<ConversationState>.Continuation] = [:]
    private var generation = 0
    private var resolvedPermissionIDs: Set<String> = []

    private var initialRefreshInFlight = false
    private var bufferedInitialEvents: [BackendEvent] = []
    private var recoveryRefreshInFlight = false
    private var droppedDeltaDuringRecovery = false
    private var reachedTerminal = false
    private var lastEventAt = Date()

    private static let maxRecoveryRefreshPasses = 3
    private static let staleTurnThreshold: TimeInterval = 45
    private static let staleTurnCheckInterval: Duration = .seconds(15)

    public init(
        backend: any CodingAgentBackend,
        sessionID: String,
        seed: [ChatMessage] = [],
        policy: ConnectionPolicy = .default,
        cache: SessionCache? = nil
    ) {
        self.backend = backend
        self.sessionID = sessionID
        self.policy = policy
        self.cache = cache
        self.reducer = MessageReducer(agentType: backend.agentType, messages: seed)
        self.loadedTranscript = !seed.isEmpty
    }

    public var messages: [ChatMessage] { reducer.snapshot }

    public var state: ConversationState {
        ConversationState(
            messages: reducer.snapshot,
            status: status,
            pendingPermissions: pendingPermissions,
            pendingQuestions: openQuestions,
            lastFailure: lastFailure,
            connection: connection,
            hasLoadedTranscript: loadedTranscript,
            goal: goal,
            compaction: compaction
        )
    }

    /// A stream of full conversation snapshots, updated as events arrive and the connection
    /// changes. Auto-reconnects with backoff.
    ///
    /// Every caller gets its own stream over one shared connection: a desktop window, a second
    /// window on the same session, and a session list can all observe at once, and the backend
    /// sees one subscriber. The run loop starts with the first observer and stops with the last.
    /// Calling this again is no longer how a client forces a reconnect — see ``reconnect()``.
    public func states() -> AsyncStream<ConversationState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationState.self, bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        startStreamIfNeeded()
        return stream
    }

    /// Drops one observer, tearing the connection down only when the last one leaves — otherwise
    /// closing a second window would end the first window's stream.
    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty else { return }
        stop()
    }

    private func startStreamIfNeeded() {
        guard streamTask == nil else { return }
        generation += 1
        let currentGeneration = generation
        streamTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
    }

    /// A run loop that returned must not leave its finished task looking like a live
    /// subscription — `startStreamIfNeeded` guards on `streamTask == nil`, so a terminal failure
    /// that kept the stale handle would make every later ``states()`` call subscribe to a stream
    /// nothing feeds, forever. Clearing it lets the next observer dial fresh; an observer that
    /// raced in between the finish and this cleanup gets the redial immediately.
    private func clearStreamTask(generation gen: Int) {
        guard gen == generation else { return }
        streamTask = nil
        if !subscribers.isEmpty { startStreamIfNeeded() }
    }

    /// Drops the current connection and dials again immediately, without disturbing any observer.
    ///
    /// A suspended app resumes holding a socket that looks alive and delivers nothing, so coming
    /// back to the foreground has to force a fresh stream. That used to be a side effect of calling
    /// ``states()`` a second time; now that a second call is a second observer, the reconnect has
    /// to be asked for.
    public func reconnect() {
        guard !subscribers.isEmpty else { return }
        generation += 1
        let currentGeneration = generation
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
    }

    /// Whether anything is currently observing — a supervisor uses this to decide when a session
    /// may be released.
    public var hasObservers: Bool { !subscribers.isEmpty }

    /// A new prompt starts a fresh turn, so the previous turn's failure is no
    /// longer current state — without this, one failed turn leaves a sticky
    /// `lastFailure` that clients re-surface after every later success.
    public func send(
        _ text: String,
        model: ModelSelection? = nil,
        reasoningEffort: String? = nil,
        agent: String? = nil,
        attachments: [PromptAttachment] = []
    ) async throws {
        lastFailure = nil
        compaction = nil
        try await backend.send(
            SendPrompt(
                text: text, model: model, reasoningEffort: reasoningEffort, agent: agent,
                attachments: attachments),
            to: sessionID)
        emit()
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await backend.respond(to: permission, decision: decision)
        resolvedPermissionIDs.insert(permission.id)
        pendingPermissions.removeAll { $0.id == permission.id }
        emit()
    }

    public func cancelCurrentTurn() async throws {
        try await backend.abort(sessionID: sessionID)
    }

    /// Runs a server-side slash command. Like ``send(_:model:reasoningEffort:agent:attachments:)``
    /// this starts a fresh turn, so a previous failure stops being current state.
    public func run(_ command: AgentCommand, arguments: String? = nil) async throws {
        lastFailure = nil
        compaction = nil
        try await backend.runCommand(command, arguments: arguments, in: sessionID)
        emit()
    }

    /// Replaces the conversation so far with a summary of it, freeing the context window.
    /// `instructions` steers what the summary must keep. The transcript is untouched — only what
    /// the agent carries forward changes — and the backend reports the boundary it left behind as
    /// a ``Compaction`` part in the transcript.
    public func compact(instructions: String? = nil) async throws {
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await run(
            AgentCommand(name: "compact", details: "", source: .builtin),
            arguments: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    /// Sets the standing goal. The agent acknowledges it and starts working immediately, so this
    /// is a turn like any other.
    public func setGoal(_ condition: String) async throws {
        try await run(
            AgentCommand(name: "goal", details: "", source: .builtin), arguments: condition)
    }

    /// Abandons the standing goal early. A goal that has been met clears itself.
    public func clearGoal() async throws {
        try await run(
            AgentCommand(name: "goal", details: "", source: .builtin), arguments: "clear")
    }

    public func answer(_ question: QuestionRequest, answers: [[String]]) async throws {
        try await backend.answerQuestion(question, answers: answers)
        resolve(question)
    }

    public func reject(_ question: QuestionRequest) async throws {
        try await backend.rejectQuestion(question)
        resolve(question)
    }

    /// Settles a question the client answered on its own — a backend whose
    /// ``BackendCapabilities/answersQuestionsByMessage`` is set is answered by
    /// the ordinary send path, so the card must stop asking without a second,
    /// unqueued message going out behind it.
    public func markAnswered(_ question: QuestionRequest) {
        resolve(question)
    }

    /// A question read out of the transcript stays in the transcript — an ask
    /// answered from here is never given a tool result, and one answered in the
    /// terminal that spawned it may not be either. Remembering what was settled
    /// keeps a resolved card from reappearing on the next refresh.
    private func resolve(_ question: QuestionRequest) {
        resolvedQuestionIDs.insert(question.id)
        pendingQuestions.removeAll { $0.id == question.id }
        transcriptQuestions.removeAll { $0.id == question.id }
        emit()
    }

    /// Questions the user still has to decide: whatever the backend pushed or
    /// the transcript implies, minus everything already answered or dismissed.
    private var openQuestions: [QuestionRequest] {
        var seen = Set<String>()
        return (pendingQuestions + transcriptQuestions).filter {
            !resolvedQuestionIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    /// Re-reads the transcript for an ask-the-user tool call still waiting on an
    /// answer. Cheap enough to run on every structural update, which is what
    /// makes a question asked mid-turn appear without its own event.
    private func syncTranscriptQuestions() {
        guard capabilitiesSupportQuestions else { return }
        transcriptQuestions = backend.pendingQuestions(
            in: reducer.snapshot, sessionID: sessionID)
    }

    private var capabilitiesSupportQuestions: Bool { backend.capabilities.supportsQuestions }

    public func refresh() async throws {
        async let questionsFetch = fetchQuestions()
        async let goalFetch = fetchGoal()
        let messages = try await backend.messages(for: sessionID)
        let (questions, goal) = await (questionsFetch, goalFetch)
        reducer = MessageReducer(agentType: backend.agentType, messages: messages)
        loadedTranscript = true
        deriveStatusFromTranscript()
        if capabilitiesSupportQuestions { pendingQuestions = questions }
        syncTranscriptQuestions()
        if backend.capabilities.supportsGoals { self.goal = goal }
        persist()
        emit()
    }

    /// A goal lookup must never fail a transcript refresh — a server too old to report goals just
    /// leaves the chip absent.
    private func fetchGoal() async -> SessionGoal? {
        guard backend.capabilities.supportsGoals else { return nil }
        return try? await backend.goal(for: sessionID)
    }

    private func fetchQuestions() async -> [QuestionRequest] {
        (try? await backend.pendingQuestions(for: sessionID)) ?? []
    }

    /// The history fetch and the event-stream connection race concurrently to overlap their
    /// latencies. Events that stream in before the snapshot lands are buffered rather than applied,
    /// then reconciled against it once it arrives: structural updates fold on top, while text deltas
    /// are dropped — their content is already in the snapshot (or restored by the next part/message
    /// upsert), so applying them would double the streamed text. Live events after the snapshot
    /// apply directly.
    private func runLoop(generation gen: Int) async {
        defer { clearStreamTask(generation: gen) }
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.staleTurnCheckInterval)
                await self?.nudgeIfStale(generation: gen)
            }
        }
        defer { watchdog.cancel() }
        recoveryRefreshInFlight = false
        droppedDeltaDuringRecovery = false
        reachedTerminal = false
        lastEventAt = Date()
        await seedFromCache(generation: gen)
        initialRefreshInFlight = true
        bufferedInitialEvents = []
        let initialRefresh = Task { [weak self] in
            await self?.completeInitialRefresh(generation: gen)
        }
        defer {
            initialRefresh.cancel()
            initialRefreshInFlight = false
            bufferedInitialEvents = []
        }

        var attempt = 0

        while gen == generation && !Task.isCancelled {
            setConnection(.connecting, generation: gen)
            do {
                for try await event in backend.events(for: sessionID) {
                    guard gen == generation else { return }
                    if initialRefreshInFlight {
                        bufferedInitialEvents.append(event)
                        continue
                    }
                    attempt = 0
                    markLive(generation: gen)
                    apply(event, generation: gen)
                }
            } catch {
                guard gen == generation else { return }
                let failure = Self.failure(from: error)
                guard failure.retryable else {
                    lastFailure = failure
                    reachedTerminal = true
                    setConnection(.offline, generation: gen)
                    finish(generation: gen)
                    return
                }
                setFailure(failure, generation: gen)
            }

            if initialRefreshInFlight { await initialRefresh.value }
            guard gen == generation && !Task.isCancelled else { return }

            attempt += 1
            if let maxAttempts = policy.maxReconnectAttempts, attempt > maxAttempts {
                setConnection(.offline, generation: gen)
                finish(generation: gen)
                return
            }

            setConnection(.reconnecting, generation: gen)
            await refreshQuietly(generation: gen)
            let delay = policy.backoffDelay(
                attempt: attempt - 1, jitterFraction: .random(in: 0...1))
            try? await Task.sleep(for: delay)
        }
    }

    /// Runs the initial history fetch, then folds in whatever streamed during it. Structural events
    /// carry full state and are replayed on top of the snapshot; text deltas are discarded to avoid
    /// double-applying content the snapshot already holds. Clearing the in-flight flag last lets
    /// subsequent live events apply directly.
    private func completeInitialRefresh(generation gen: Int) async {
        await refreshQuietly(generation: gen)
        guard gen == generation, !reachedTerminal else {
            bufferedInitialEvents = []
            initialRefreshInFlight = false
            return
        }
        let buffered = bufferedInitialEvents
        bufferedInitialEvents = []
        if !buffered.isEmpty {
            markLive(generation: gen)
            for event in buffered {
                if case .partTextDelta = event { continue }
                apply(event, generation: gen)
            }
        }
        initialRefreshInFlight = false
    }

    private func markLive(generation gen: Int) {
        guard connection != .live else { return }
        lastFailure = nil
        setConnection(.live, generation: gen)
    }

    /// Builds a failure from a stream/refresh error, classifying its retryability so the reconnect
    /// loop can stop hammering a permanently-failing endpoint. Non-``AgentError`` errors default to
    /// retryable, preserving backoff for unrecognised transport faults.
    /// The banner never shows a raw error dump. A transport error's `describing` is a paragraph
    /// of `Error Domain=NSURLErrorDomain …` — that goes in `detail` for the log; the message a
    /// person sees names the situation in one clause.
    private static func failure(from error: Error) -> BackendFailure {
        let retryable = (error as? AgentError)?.isRetryable ?? true
        var message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if let urlError = error as? URLError {
            message = urlError.localizedDescription
        }
        if message.count > 120 || message.contains("Error Domain") || message.contains("Code=") {
            message = AgentText.string("The server can't be reached right now.")
        }
        return BackendFailure(
            message: message, retryable: retryable, detail: String(describing: error))
    }

    /// A turn that claims to be running while its events have stopped arriving is either a slow
    /// model or a stream that died without saying so — a socket kept alive by heartbeats delivers
    /// nothing for this session and trips no other watchdog, and the reader is left watching half
    /// an answer forever. The transcript on the server is whole either way, so a quiet refetch is
    /// the one move that is free when the turn is merely slow and healing when it is not.
    private func nudgeIfStale(generation gen: Int) async {
        guard gen == generation, status == .running, connection == .live,
            !initialRefreshInFlight, !recoveryRefreshInFlight,
            Date().timeIntervalSince(lastEventAt) > Self.staleTurnThreshold
        else { return }
        lastEventAt = Date()
        await refreshQuietly(generation: gen)
    }

    private func apply(_ event: BackendEvent, generation gen: Int) {
        guard gen == generation else { return }
        lastEventAt = Date()
        switch event {
        case .partTextDelta(let messageID, let partID, _):
            if reducer.hasPart(messageID: messageID, partID: partID) {
                reducer.apply(event)
            } else {
                scheduleRecoveryRefresh(generation: gen)
            }
            if status != .running, impliesRunning(event) { status = .running }
        case .messageUpserted, .partUpserted, .partRemoved, .messageRemoved:
            reducer.apply(event)
            syncTranscriptQuestions()
            if status != .running, impliesRunning(event) { status = .running }
            persistDuringStream()
        case .status(let value):
            status = value
            if value == .idle || value == .stable { persist() }
        case .goal(let value):
            goal = value
        case .compaction(let value):
            compaction = value
        case .permission(let request):
            guard !resolvedPermissionIDs.contains(request.id) else { break }
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
            }
        case .permissionResolved(let requestID):
            resolvedPermissionIDs.insert(requestID)
            pendingPermissions.removeAll { $0.id == requestID }
        case .question(let request):
            if !pendingQuestions.contains(where: { $0.id == request.id }) {
                pendingQuestions.append(request)
            }
        case .questionResolved(let requestID):
            resolvedQuestionIDs.insert(requestID)
            pendingQuestions.removeAll { $0.id == requestID }
            transcriptQuestions.removeAll { $0.id == requestID }
        case .failure(let failure):
            lastFailure = failure
            if status == .running { status = .idle }
        case .unknown:
            break
        }
        emit()
    }

    /// Live streaming activity on an unfinished assistant message means a turn
    /// is in flight — some backends (opencode) never send an explicit running
    /// status, so it has to be inferred or clients never see a busy state.
    /// Backends that never stamp `completedAt` (claude-bridge) get no upsert
    /// inference at all: there a nil `completedAt` is meaningless, and a late
    /// message upsert landing after the terminal idle would re-arm a running
    /// state that nothing could ever clear again. Text deltas still count —
    /// they only flow while tokens actually stream.
    private func impliesRunning(_ event: BackendEvent) -> Bool {
        switch event {
        case .partTextDelta:
            return reducer.snapshot.last?.role == .assistant
        case .messageUpserted(let message, _):
            guard backend.capabilities.reportsMessageCompletion else { return false }
            return message.role == .assistant && message.completedAt == nil
        case .partUpserted(let messageID, _):
            guard backend.capabilities.reportsMessageCompletion else { return false }
            guard let message = reducer.snapshot.last(where: { $0.id == messageID }) else {
                return false
            }
            return message.role == .assistant && message.completedAt == nil
        default:
            return false
        }
    }

    /// A delta for a part we don't have means our transcript diverged from
    /// the server's (e.g. a reconnect gap). Appending it would fabricate a
    /// bubble that starts mid-response, so drop it and re-fetch instead. A
    /// drop that lands while a recovery fetch is already in flight is recorded
    /// so the fetch reruns and converges rather than silently losing the delta.
    private func scheduleRecoveryRefresh(generation gen: Int) {
        guard !recoveryRefreshInFlight else {
            droppedDeltaDuringRecovery = true
            return
        }
        recoveryRefreshInFlight = true
        Task { [weak self] in
            await self?.recoveryRefresh(generation: gen)
        }
    }

    /// Re-fetches the transcript, then repeats while deltas kept dropping during the fetch — each
    /// pass narrows the gap to a single roundtrip so a burst of deltas for a still-missing part
    /// can't leave a permanent hole. Bounded so a continuously-streaming turn can't refetch forever;
    /// any residual gap heals at the next full part/message upsert.
    private func recoveryRefresh(generation gen: Int) async {
        var passes = 0
        repeat {
            droppedDeltaDuringRecovery = false
            await refreshQuietly(generation: gen)
            guard gen == generation else { break }
            passes += 1
        } while droppedDeltaDuringRecovery && passes < Self.maxRecoveryRefreshPasses
        recoveryRefreshInFlight = false
    }

    /// The transcript is the source of truth after a refresh: status events
    /// that fired while we were disconnected are gone forever, so a completed
    /// or visibly-streaming last message must correct a stale status.
    private func deriveStatusFromTranscript() {
        guard let last = reducer.snapshot.last, last.role == .assistant else { return }
        if last.completedAt != nil {
            if status == .running { status = .idle }
        } else if last.isStreaming {
            if status != .running { status = .running }
        }
    }

    private func seedFromCache(generation gen: Int) async {
        guard let cache, reducer.snapshot.isEmpty else { return }
        let cached = await cache.messages(for: sessionID)
        guard gen == generation, !cached.isEmpty, reducer.snapshot.isEmpty else { return }
        reducer = MessageReducer(agentType: backend.agentType, messages: cached)
        loadedTranscript = true
        syncTranscriptQuestions()
        emit()
    }

    /// The three initial fetches ride concurrently: on a bridge answering a heavy machine each
    /// round trip can cost real time, and paying them in sequence is what made a freshly opened
    /// chat sit on its placeholder.
    private func refreshQuietly(generation gen: Int) async {
        do {
            async let questionsFetch = fetchQuestions()
            async let goalFetch = fetchGoal()
            let messages = try await backend.messages(for: sessionID)
            let (questions, goal) = await (questionsFetch, goalFetch)
            guard gen == generation, !reachedTerminal else { return }
            reducer = MessageReducer(agentType: backend.agentType, messages: messages)
            loadedTranscript = true
            deriveStatusFromTranscript()
            if capabilitiesSupportQuestions { pendingQuestions = questions }
            syncTranscriptQuestions()
            if backend.capabilities.supportsGoals { self.goal = goal }
            lastFailure = nil
            persist()
            emit()
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation, !reachedTerminal else { return }
            lastFailure = Self.failure(from: error)
            emit()
        }
    }

    /// A turn can stream for an hour; a cache written only at idle restores an hour stale. Every
    /// few seconds of applied events reaches disk, so a relaunch mid-turn reopens on the newest
    /// content the app ever saw rather than on the last completed turn.
    private func persistDuringStream() {
        guard Date().timeIntervalSince(lastStreamPersist) > 5 else { return }
        persist()
    }

    /// Chains onto the previous persist so writes reach the cache in order;
    /// a cancelled predecessor may still complete, but never after this one.
    private func persist() {
        guard let cache else { return }
        lastStreamPersist = Date()
        let snapshot = reducer.snapshot
        let sessionID = sessionID
        persistTask = Task { [previous = persistTask] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await cache.store(snapshot, for: sessionID)
        }
    }

    private func setConnection(_ phase: ConnectionPhase, generation gen: Int) {
        guard gen == generation else { return }
        connection = phase
        emit()
    }

    private func setFailure(_ failure: BackendFailure, generation gen: Int) {
        guard gen == generation else { return }
        lastFailure = failure
        emit()
    }

    private func emit() {
        let snapshot = state
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func finish(generation gen: Int) {
        guard gen == generation else { return }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        persistTask?.cancel()
        persistTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}
