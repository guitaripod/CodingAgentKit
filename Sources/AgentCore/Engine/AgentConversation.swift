import Foundation

public actor AgentConversation {
    public let backend: any CodingAgentBackend
    public let sessionID: String

    private let policy: ConnectionPolicy
    private let cache: SessionCache?

    private var reducer: MessageReducer
    private var status: BackendStatus = .unknown
    private var pendingPermissions: [PermissionRequest] = []
    private var lastFailure: BackendFailure?
    private var connection: ConnectionPhase = .connecting

    private var streamTask: Task<Void, Never>?
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

        let (stream, continuation) = AsyncStream.makeStream(of: ConversationState.self)
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
        agent: String? = nil,
        attachments: [PromptAttachment] = []
    ) async throws {
        try await backend.send(
            SendPrompt(text: text, model: model, agent: agent, attachments: attachments),
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

    public func refresh() async throws {
        let messages = try await backend.messages(for: sessionID)
        reducer = MessageReducer(agentType: backend.agentType, messages: messages)
        persist()
        emit()
    }

    private func runLoop(generation gen: Int) async {
        await seedFromCache(generation: gen)
        await refreshQuietly(generation: gen)

        var attempt = 0
        var sseFailures = 0

        while gen == generation && !Task.isCancelled {
            setConnection(.connecting, generation: gen)
            do {
                for try await event in eventStream(sseFailures: sseFailures) {
                    guard gen == generation else { return }
                    if connection != .live { setConnection(.live, generation: gen) }
                    attempt = 0
                    sseFailures = 0
                    apply(event, generation: gen)
                }
            } catch {
                guard gen == generation else { return }
                sseFailures += 1
                setFailure(
                    BackendFailure(message: String(describing: error), retryable: true),
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

    private func eventStream(sseFailures: Int) -> AsyncThrowingStream<BackendEvent, Error> {
        if let poller = backend as? PollingBackend,
            let threshold = policy.pollFallbackAfterFailures,
            sseFailures >= threshold
        {
            return poller.pollingEvents(for: sessionID, interval: .seconds(1))
        }
        return backend.events(for: sessionID)
    }

    private func apply(_ event: BackendEvent, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .messageUpserted, .partUpserted, .partTextDelta, .partRemoved, .messageRemoved:
            reducer.apply(event)
        case .status(let value):
            status = value
            if value == .idle || value == .stable { persist() }
        case .permission(let request):
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
            }
        case .failure(let failure):
            lastFailure = failure
        case .unknown:
            break
        }
        emit()
    }

    private func seedFromCache(generation gen: Int) async {
        guard let cache, reducer.snapshot.isEmpty else { return }
        let cached = await cache.messages(for: sessionID)
        guard gen == generation, !cached.isEmpty, reducer.snapshot.isEmpty else { return }
        reducer = MessageReducer(agentType: backend.agentType, messages: cached)
        emit()
    }

    private func refreshQuietly(generation gen: Int) async {
        guard let messages = try? await backend.messages(for: sessionID), gen == generation else {
            return
        }
        reducer = MessageReducer(agentType: backend.agentType, messages: messages)
        persist()
        emit()
    }

    private func persist() {
        guard let cache else { return }
        let snapshot = reducer.snapshot
        let sessionID = sessionID
        Task { await cache.store(snapshot, for: sessionID) }
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
        continuation?.finish()
        continuation = nil
    }
}
