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

/// Where the server's own record of one conversation stands, cheap enough to ask on a clock.
///
/// An event stream carries the turns the server ran for the process holding it, which is not the
/// same set as the turns that happened in the session: a machine can be writing the same transcript
/// from another process entirely — `opencode run` under a script, a second serve, an agent somebody
/// started in a terminal — and none of it reaches a bus this connection is not on. The record is
/// what sees that work, so a client that must not miss it reads this rather than trusting silence.
public struct SessionRevision: Sendable, Hashable {
    /// When the server last wrote to this conversation, by the server's own clock. Only ever
    /// compared against another reading of the same clock. `nil` from a server that keeps the
    /// session but stamps nothing, which is *cannot say* rather than *has not changed*.
    public var updatedAt: Date?

    public init(updatedAt: Date?) {
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
    /// The door the session's model runs through, when the backend reports one
    /// separately from the model's name. Two gateways offering the same model id
    /// bill it differently, so the door is the difference between "this session
    /// spends from the plan" and "this session spends from its own key".
    public var modelProviderID: String?
    public var reasoningEffort: String?
    /// Agents working for this session right now. A session that has handed its
    /// turn to subagents is live while its own transcript stays silent, so this
    /// is what a list has to describe it with.
    public var activeAgents: Int?
    /// What the single working agent was sent to do; nil when several are
    /// working, or none.
    public var agentTask: String?

    /// The ``ConnectionProfile`` id of the machine this session came from, stamped by
    /// ``FederatedSessionList`` as it merges hosts — a backend cannot know its own host id, and a
    /// session read straight from one leaves this nil, where there is only one machine and the
    /// question does not arise.
    public var hostID: String?

    /// Host-scoped identity, once ``hostID`` has been stamped. Nil means the session was never
    /// merged across hosts, so the caller already knows which machine it asked.
    public var ref: SessionRef? { hostID.map { SessionRef(hostID: $0, sessionID: id) } }

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
        modelProviderID: String? = nil,
        reasoningEffort: String? = nil,
        activeAgents: Int? = nil,
        agentTask: String? = nil,
        hostID: String? = nil
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
        self.modelProviderID = modelProviderID
        self.reasoningEffort = reasoningEffort
        self.activeAgents = activeAgents
        self.agentTask = agentTask
        self.hostID = hostID
    }
}
