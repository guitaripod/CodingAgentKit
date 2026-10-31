public protocol SessionCache: Sendable {
    func sessions(for agentType: AgentType) async -> [AgentSession]
    func store(_ sessions: [AgentSession], for agentType: AgentType) async
    func messages(for sessionID: String) async -> [ChatMessage]
    func store(_ messages: [ChatMessage], for sessionID: String) async
    /// How many bytes the last `store(_:for:)` of this transcript put on disk, or zero when the
    /// cache keeps nothing on disk or does not know. A conversation spaces its writes by it: a
    /// write is the whole transcript, so what it costs is what the transcript weighs.
    func lastStoredBytes(for sessionID: String) async -> Int
}

extension SessionCache {
    public func lastStoredBytes(for sessionID: String) async -> Int { 0 }
}

public actor InMemorySessionCache: SessionCache {
    private var sessionsByAgent: [AgentType: [AgentSession]] = [:]
    private var messagesBySession: [String: [ChatMessage]] = [:]
    var sessionsByHost: [String: [AgentSession]] = [:]

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
