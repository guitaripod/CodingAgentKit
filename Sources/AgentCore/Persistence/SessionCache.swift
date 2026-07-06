public protocol SessionCache: Sendable {
    func sessions(for agentType: AgentType) async -> [AgentSession]
    func store(_ sessions: [AgentSession], for agentType: AgentType) async
    func messages(for sessionID: String) async -> [ChatMessage]
    func store(_ messages: [ChatMessage], for sessionID: String) async
}

public actor InMemorySessionCache: SessionCache {
    private var sessionsByAgent: [AgentType: [AgentSession]] = [:]
    private var messagesBySession: [String: [ChatMessage]] = [:]

    public init() {}

    public func sessions(for agentType: AgentType) async -> [AgentSession] {
        sessionsByAgent[agentType] ?? []
    }

    public func store(_ sessions: [AgentSession], for agentType: AgentType) async {
        sessionsByAgent[agentType] = sessions
    }

    public func messages(for sessionID: String) async -> [ChatMessage] {
        messagesBySession[sessionID] ?? []
    }

    public func store(_ messages: [ChatMessage], for sessionID: String) async {
        messagesBySession[sessionID] = messages
    }
}
