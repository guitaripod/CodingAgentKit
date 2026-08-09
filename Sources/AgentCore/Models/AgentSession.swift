import Foundation

/// A worktree the backend keeps sessions for. Backends that scope their session
/// list to one project at a time expose the rest through this.
public struct AgentProject: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var worktree: String
    public var updatedAt: Date?

    public init(id: String, worktree: String, updatedAt: Date? = nil) {
        self.id = id
        self.worktree = worktree
        self.updatedAt = updatedAt
    }
}

public struct AgentSession: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let agentType: AgentType
    public var title: String
    public var parentID: String?
    public var directory: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// The session's transcript is being written to right now — an agent is
    /// actively working in it (on the server machine or via this client).
    public var isActive: Bool?
    /// Model the session last ran with, as the backend reports it (an alias
    /// like "sonnet" or a full id like "claude-fable-5"); nil when the
    /// backend's session list doesn't carry one.
    public var model: String?
    public var reasoningEffort: String?
    /// Agents working for this session right now. A session that has handed its
    /// turn to subagents is live while its own transcript stays silent, so this
    /// is what a list has to describe it with.
    public var activeAgents: Int?
    /// What the single working agent was sent to do; nil when several are
    /// working, or none.
    public var agentTask: String?

    /// Live work is happening for this session — its own turn is in flight, or
    /// agents it spawned are still running.
    public var isWorking: Bool { isActive == true || (activeAgents ?? 0) > 0 }

    /// A transcript a spawned agent was given, not a conversation someone had.
    /// Servers that give a subagent a session of its own (opencode does) report
    /// it parented to the session that spawned it; it belongs nested at that
    /// tool call, and never in a list of chats.
    public var isSubagent: Bool { parentID != nil }

    public init(
        id: String,
        agentType: AgentType,
        title: String,
        parentID: String? = nil,
        directory: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        isActive: Bool? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        activeAgents: Int? = nil,
        agentTask: String? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.title = title
        self.parentID = parentID
        self.directory = directory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.activeAgents = activeAgents
        self.agentTask = agentTask
    }
}
