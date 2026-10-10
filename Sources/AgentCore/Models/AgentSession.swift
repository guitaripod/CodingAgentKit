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
    /// Whether the server holds a turn open in this conversation right now. `nil` from a server
    /// that keeps no such fact on its record, which is *cannot say* rather than *idle*.
    public var running: Bool?
    /// Work the agent's process is carrying with no turn open; `nil` when there is none, or from a
    /// server with no such notion.
    public var backgroundWork: BackgroundWork?

    public init(updatedAt: Date?, running: Bool? = nil, backgroundWork: BackgroundWork? = nil) {
        self.updatedAt = updatedAt
        self.running = running
        self.backgroundWork = backgroundWork
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
    /// The conversation is bookmarked on the server that holds it. Nil from a backend with no
    /// notion of a bookmark, which is not the same as `false` — the mark is then the device's own.
    public var saved: Bool?
    /// Work the agent's process is still carrying with no turn open — a command it started and
    /// stepped back from. The turn is over and the prompt is free, but the machine is still busy
    /// for this chat and the agent will speak again when the work ends, so a list must not file
    /// it with everything that finished. Nil when there is none, or from a backend with no such
    /// notion.
    public var backgroundWork: BackgroundWork?
    /// The conversation is pinned to the top on the server that holds it, so every client the
    /// server answers keeps the same shortlist. Nil from a server that keeps no such mark — which
    /// is *cannot say*, never *not pinned* — and the mark is then the device's own.
    public var pinned: Bool?
    /// When it was pinned, by the server's clock. Pins are ordered by it on every client, so the
    /// order a person made them in is the order they read in wherever they look.
    public var pinnedAt: Date?
    /// The conversation is set aside on the server that holds it. Nil as for ``pinned``.
    public var archived: Bool?
    /// The reference time of the person's last look, by the server's clock, which is the clock
    /// ``updatedAt`` is read on — so a chat is unread exactly when it has moved on past this, whatever
    /// the clock of the device that looked. Nil when no device has marked the chat either way.
    public var readAt: Date?

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
        saved: Bool? = nil,
        hostID: String? = nil,
        backgroundWork: BackgroundWork? = nil,
        pinned: Bool? = nil,
        pinnedAt: Date? = nil,
        archived: Bool? = nil,
        readAt: Date? = nil
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
        self.saved = saved
        self.hostID = hostID
        self.backgroundWork = backgroundWork
        self.pinned = pinned
        self.pinnedAt = pinnedAt
        self.archived = archived
        self.readAt = readAt
    }

    /// Whether the server reports this person's marks at all. A listing that says `false` for a
    /// pin is a server that speaks them; one that says nothing is a server that cannot.
    public var reportsMarks: Bool { pinned != nil }
}

/// What a person decided about one conversation, for the server that holds it to keep. Each field
/// is optional because a press changes one thing, and `at` is when the person decided, by this
/// device's clock: a decision made while the server was out of reach is delivered late, and the
/// server weighs it against what was decided meanwhile by when it was made rather than when it
/// arrived.
public struct SessionMarkChange: Sendable, Hashable {
    public enum Read: String, Sendable, Hashable {
        /// The person has looked at everything the chat holds.
        case seen
        /// The person set the chat aside to come back to.
        case unread
    }

    public var saved: Bool?
    public var pinned: Bool?
    public var archived: Bool?
    public var read: Read?
    public var at: Date

    public init(
        saved: Bool? = nil, pinned: Bool? = nil, archived: Bool? = nil, read: Read? = nil,
        at: Date = Date()
    ) {
        self.saved = saved
        self.pinned = pinned
        self.archived = archived
        self.read = read
        self.at = at
    }

    public var isEmpty: Bool { saved == nil && pinned == nil && archived == nil && read == nil }
}
