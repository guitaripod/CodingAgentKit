import Foundation

/// What a server said when asked whether it is holding a turn its machine cut off. A server that
/// cannot answer is not a server that said no: only ``answered`` may change what a client shows,
/// so an unsupported route leaves a standing card alone rather than clearing it into a false
/// all-clear.
public enum InterruptionReading: Sendable, Hashable {
    case answered(TurnInterruption?)
    case cannotSay
}

public enum ConnectionPhase: String, Sendable, Hashable, Codable {
    case connecting
    case live
    case reconnecting
    case offline
}

/// An immutable snapshot of a conversation: the transcript plus live status, pending permission
/// prompts, the last failure, and the connection phase. Observe a stream of these from
/// ``AgentConversation/states()`` to drive a UI.
public struct ConversationState: Sendable, Hashable, Codable {
    public var messages: [ChatMessage]
    public var status: BackendStatus
    public var pendingPermissions: [PermissionRequest]
    public var pendingQuestions: [QuestionRequest]
    public var lastFailure: BackendFailure?
    public var connection: ConnectionPhase
    public var hasLoadedTranscript: Bool
    /// The standing goal the agent is working toward, or the last one it settled. `nil` when the
    /// backend doesn't track goals or none was ever set.
    public var goal: SessionGoal?
    /// A compaction underway, or the one that just failed. `nil` whenever nothing is being
    /// summarized — which is almost always.
    public var compaction: CompactionActivity?
    /// A turn the server's own machine cut off and has not been told what to do about. `nil` when
    /// nothing was interrupted, when the work was picked back up or let go, and on any backend
    /// that cannot tell the difference — a client must never render its absence as proof that a
    /// turn finished.
    public var interruption: TurnInterruption?
    /// Work the agent's process is carrying with no turn open — a command it started and stepped
    /// back from, an agent it backgrounded. `status` is idle throughout and the prompt is free,
    /// but the machine is still working for this conversation and the agent will speak again on
    /// its own when it ends, so a surface must not draw it as a conversation that finished. `nil`
    /// when there is none, and always on a backend with no such notion.
    public var backgroundWork: BackgroundWork?
    /// When the connection last became what it is. A phase with no clock on it cannot be told
    /// apart from a phase that is stuck, so every surface that reports one reports how long it has
    /// been true.
    public var connectionChangedAt: Date = .distantPast
    /// The provider wait the open turn is in: the last attempt failed and the server will try
    /// again. `nil` whenever an attempt is answering, the turn is over, or the backend never says.
    public var retry: TurnRetry?
    /// The revert standing on the conversation. While one stands, ``messages`` is the conversation
    /// as it was before the boundary and ``revertedMessages`` holds what was set aside, so every
    /// surface that reads the transcript reads the one that is in effect.
    public var revert: SessionRevert?
    /// The messages a standing revert set aside, oldest first; empty when nothing is reverted.
    public var revertedMessages: [ChatMessage] = []
    /// The prompts waiting on the server behind the running turn, in arrival order, as every
    /// client of the conversation sees them. Empty on a backend that keeps no server queue
    /// (``BackendCapabilities/supportsServerQueue``), where queueing is the client's own.
    public var queue: [QueuedPrompt] = []
    /// Whether the server holds the queue back after a Stop: the items stay and nothing starts
    /// until a new message or ``AgentConversation/resumeQueue()``.
    public var queuePaused: Bool = false

    public init(
        messages: [ChatMessage] = [],
        status: BackendStatus = .unknown,
        pendingPermissions: [PermissionRequest] = [],
        pendingQuestions: [QuestionRequest] = [],
        lastFailure: BackendFailure? = nil,
        connection: ConnectionPhase = .connecting,
        hasLoadedTranscript: Bool = false,
        goal: SessionGoal? = nil,
        compaction: CompactionActivity? = nil,
        interruption: TurnInterruption? = nil,
        connectionChangedAt: Date = .distantPast,
        backgroundWork: BackgroundWork? = nil,
        retry: TurnRetry? = nil,
        revert: SessionRevert? = nil,
        revertedMessages: [ChatMessage] = [],
        queue: [QueuedPrompt] = [],
        queuePaused: Bool = false
    ) {
        self.messages = messages
        self.status = status
        self.pendingPermissions = pendingPermissions
        self.pendingQuestions = pendingQuestions
        self.lastFailure = lastFailure
        self.connection = connection
        self.hasLoadedTranscript = hasLoadedTranscript
        self.goal = goal
        self.compaction = compaction
        self.interruption = interruption
        self.connectionChangedAt = connectionChangedAt
        self.backgroundWork = backgroundWork
        self.retry = retry
        self.revert = revert
        self.revertedMessages = revertedMessages
        self.queue = queue
        self.queuePaused = queuePaused
    }

    /// A state cached before the queue existed has no queue in it, and that is an empty queue
    /// rather than a state that cannot be read.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        status = try container.decode(BackendStatus.self, forKey: .status)
        pendingPermissions = try container.decode(
            [PermissionRequest].self, forKey: .pendingPermissions)
        pendingQuestions = try container.decode([QuestionRequest].self, forKey: .pendingQuestions)
        lastFailure = try container.decodeIfPresent(BackendFailure.self, forKey: .lastFailure)
        connection = try container.decode(ConnectionPhase.self, forKey: .connection)
        hasLoadedTranscript = try container.decode(Bool.self, forKey: .hasLoadedTranscript)
        goal = try container.decodeIfPresent(SessionGoal.self, forKey: .goal)
        compaction = try container.decodeIfPresent(CompactionActivity.self, forKey: .compaction)
        interruption = try container.decodeIfPresent(TurnInterruption.self, forKey: .interruption)
        backgroundWork = try container.decodeIfPresent(BackgroundWork.self, forKey: .backgroundWork)
        connectionChangedAt = try container.decode(Date.self, forKey: .connectionChangedAt)
        retry = try container.decodeIfPresent(TurnRetry.self, forKey: .retry)
        revert = try container.decodeIfPresent(SessionRevert.self, forKey: .revert)
        revertedMessages = try container.decode([ChatMessage].self, forKey: .revertedMessages)
        queue = try container.decodeIfPresent([QueuedPrompt].self, forKey: .queue) ?? []
        queuePaused = try container.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? false
    }

    public var isBusy: Bool { status == .running }

    /// A compaction actually in flight — a failed attempt stays in ``compaction`` so a client can
    /// explain it, but must not read as work still happening.
    public var activeCompaction: CompactionActivity? {
        compaction.flatMap { $0.isRunning ? $0 : nil }
    }

    /// The goal still being pursued, if any — a settled goal stays in ``goal`` so a client can
    /// report the outcome, but must not present it as ongoing work.
    public var activeGoal: SessionGoal? { goal.flatMap { $0.isActive ? $0 : nil } }

    /// True while the transcript may still be on its way: nothing has been
    /// loaded yet (no cache seed, no server fetch) — distinguish this from a
    /// genuinely empty conversation before showing an empty state.
    public var isLoadingTranscript: Bool { !hasLoadedTranscript && messages.isEmpty }
}
