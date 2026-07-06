public actor AgentConversation {
    public let backend: any CodingAgentBackend
    public let sessionID: String
    private var reducer: MessageReducer
    private var streamTask: Task<Void, Never>?
    private var continuation: AsyncStream<[ChatMessage]>.Continuation?
    private var generation = 0

    public init(backend: any CodingAgentBackend, sessionID: String, seed: [ChatMessage] = []) {
        self.backend = backend
        self.sessionID = sessionID
        self.reducer = MessageReducer(agentType: backend.agentType, messages: seed)
    }

    public var messages: [ChatMessage] {
        reducer.snapshot
    }

    public func stream() -> AsyncStream<[ChatMessage]> {
        streamTask?.cancel()
        continuation?.finish()
        generation += 1
        let currentGeneration = generation

        let (stream, continuation) = AsyncStream.makeStream(of: [ChatMessage].self)
        self.continuation = continuation
        continuation.yield(reducer.snapshot)

        let events = backend.events(for: sessionID)
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in events {
                    await self.apply(event, generation: currentGeneration)
                }
            } catch {
                await self.fail(error, generation: currentGeneration)
            }
            await self.finish(generation: currentGeneration)
        }

        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop(generation: currentGeneration) }
        }
        return stream
    }

    public func send(_ text: String, model: ModelSelection? = nil, agent: String? = nil)
        async throws
    {
        try await backend.send(SendPrompt(text: text, model: model, agent: agent), to: sessionID)
    }

    public func abort() async throws {
        try await backend.abort(sessionID: sessionID)
    }

    public func refresh() async throws {
        let messages = try await backend.messages(for: sessionID)
        reducer = MessageReducer(agentType: backend.agentType, messages: messages)
        continuation?.yield(reducer.snapshot)
    }

    private func apply(_ event: BackendEvent, generation: Int) {
        guard generation == self.generation else { return }
        reducer.apply(event)
        continuation?.yield(reducer.snapshot)
    }

    private func fail(_ error: Error, generation: Int) {
        guard generation == self.generation else { return }
        reducer.apply(.failure(String(describing: error)))
        continuation?.yield(reducer.snapshot)
    }

    private func finish(generation: Int) {
        guard generation == self.generation else { return }
        continuation?.finish()
    }

    private func stop(generation: Int) {
        guard generation == self.generation else { return }
        streamTask?.cancel()
        streamTask = nil
        continuation?.finish()
        continuation = nil
    }
}
