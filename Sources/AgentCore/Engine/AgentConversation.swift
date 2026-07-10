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
    private var lastFailure: BackendFailure?
    private var connection: ConnectionPhase = .connecting

    private var streamTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var continuation: AsyncStream<ConversationState>.Continuation?
    private var generation = 0

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
    }

    public var messages: [ChatMessage] { reducer.snapshot }

    public var state: ConversationState {
        ConversationState(
            messages: reducer.snapshot,
            status: status,
            pendingPermissions: pendingPermissions,
            pendingQuestions: pendingQuestions,
            lastFailure: lastFailure,
            connection: connection
        )
    }

    /// A stream of full conversation snapshots, updated as events arrive and the connection changes.
    /// Auto-reconnects with backoff; calling again supersedes the previous stream.
    public func states() -> AsyncStream<ConversationState> {
        stop()
        generation += 1
        let currentGeneration = generation

        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationState.self, bufferingPolicy: .bufferingNewest(1))
        self.continuation = continuation
        continuation.yield(state)

        streamTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(generation: currentGeneration) }
        }
        return stream
    }

    public func send(
        _ text: String,
        model: ModelSelection? = nil,
        reasoningEffort: String? = nil,
        agent: String? = nil,
        attachments: [PromptAttachment] = []
    ) async throws {
        try await backend.send(
            SendPrompt(
                text: text, model: model, reasoningEffort: reasoningEffort, agent: agent,
                attachments: attachments),
            to: sessionID)
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await backend.respond(to: permission, decision: decision)
        pendingPermissions.removeAll { $0.id == permission.id }
        emit()
    }

    public func cancelCurrentTurn() async throws {
        try await backend.abort(sessionID: sessionID)
    }

    public func answer(_ question: QuestionRequest, answers: [[String]]) async throws {
        try await backend.answerQuestion(question, answers: answers)
        pendingQuestions.removeAll { $0.id == question.id }
        emit()
    }

    public func reject(_ question: QuestionRequest) async throws {
        try await backend.rejectQuestion(question)
        pendingQuestions.removeAll { $0.id == question.id }
        emit()
    }

    private var capabilitiesSupportQuestions: Bool { backend.capabilities.supportsQuestions }

    public func refresh() async throws {
        let messages = try await backend.messages(for: sessionID)
        let questions = (try? await backend.pendingQuestions(for: sessionID)) ?? []
        reducer = MessageReducer(agentType: backend.agentType, messages: messages)
        deriveStatusFromTranscript()
        if capabilitiesSupportQuestions { pendingQuestions = questions }
        persist()
        emit()
    }

    private func runLoop(generation gen: Int) async {
        await seedFromCache(generation: gen)
        await refreshQuietly(generation: gen)

        var attempt = 0

        while gen == generation && !Task.isCancelled {
            setConnection(.connecting, generation: gen)
            do {
                for try await event in backend.events(for: sessionID) {
                    guard gen == generation else { return }
                    if connection != .live {
                        lastFailure = nil
                        setConnection(.live, generation: gen)
                    }
                    attempt = 0
                    apply(event, generation: gen)
                }
            } catch {
                guard gen == generation else { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                setFailure(
                    BackendFailure(message: msg, retryable: true, detail: String(describing: error)),
                    generation: gen)
            }

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

    private func apply(_ event: BackendEvent, generation gen: Int) {
        guard gen == generation else { return }
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
            if status != .running, impliesRunning(event) { status = .running }
        case .status(let value):
            status = value
            if value == .idle || value == .stable { persist() }
        case .permission(let request):
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
            }
        case .question(let request):
            if !pendingQuestions.contains(where: { $0.id == request.id }) {
                pendingQuestions.append(request)
            }
        case .questionResolved(let requestID):
            pendingQuestions.removeAll { $0.id == requestID }
        case .failure(let failure):
            lastFailure = failure
        case .unknown:
            break
        }
        emit()
    }

    /// Live streaming activity on an unfinished assistant message means a turn
    /// is in flight — some backends (opencode) never send an explicit running
    /// status, so it has to be inferred or clients never see a busy state.
    private func impliesRunning(_ event: BackendEvent) -> Bool {
        switch event {
        case .partTextDelta:
            return reducer.snapshot.last?.role == .assistant
        case .messageUpserted(let message, _):
            return message.role == .assistant && message.completedAt == nil
        case .partUpserted(let messageID, _):
            guard let message = reducer.snapshot.last(where: { $0.id == messageID }) else {
                return false
            }
            return message.role == .assistant && message.completedAt == nil
        default:
            return false
        }
    }

    private var recoveryRefreshInFlight = false

    /// A delta for a part we don't have means our transcript diverged from
    /// the server's (e.g. a reconnect gap). Appending it would fabricate a
    /// bubble that starts mid-response, so drop it and re-fetch instead.
    private func scheduleRecoveryRefresh(generation gen: Int) {
        guard !recoveryRefreshInFlight else { return }
        recoveryRefreshInFlight = true
        Task { [weak self] in
            await self?.recoveryRefresh(generation: gen)
        }
    }

    private func recoveryRefresh(generation gen: Int) async {
        await refreshQuietly(generation: gen)
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
        emit()
    }

    private func refreshQuietly(generation gen: Int) async {
        do {
            let messages = try await backend.messages(for: sessionID)
            let questions = (try? await backend.pendingQuestions(for: sessionID)) ?? []
            guard gen == generation else { return }
            reducer = MessageReducer(agentType: backend.agentType, messages: messages)
            deriveStatusFromTranscript()
            if capabilitiesSupportQuestions { pendingQuestions = questions }
            lastFailure = nil
            persist()
            emit()
        } catch is CancellationError {
            return
        } catch {
            guard gen == generation else { return }
            let msg = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lastFailure = BackendFailure(
                message: msg, retryable: true, detail: String(describing: error))
            emit()
        }
    }

    /// Chains onto the previous persist so writes reach the cache in order;
    /// a cancelled predecessor may still complete, but never after this one.
    private func persist() {
        guard let cache else { return }
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
        continuation?.yield(state)
    }

    private func finish(generation gen: Int) {
        guard gen == generation else { return }
        continuation?.finish()
    }

    private func stop(generation gen: Int) {
        guard gen == generation else { return }
        stop()
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        persistTask?.cancel()
        persistTask = nil
        continuation?.finish()
        continuation = nil
    }
}
