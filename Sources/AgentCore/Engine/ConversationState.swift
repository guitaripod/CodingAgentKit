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

    public init(
        messages: [ChatMessage] = [],
        status: BackendStatus = .unknown,
        pendingPermissions: [PermissionRequest] = [],
        pendingQuestions: [QuestionRequest] = [],
        lastFailure: BackendFailure? = nil,
        connection: ConnectionPhase = .connecting,
        hasLoadedTranscript: Bool = false,
        goal: SessionGoal? = nil
    ) {
        self.messages = messages
        self.status = status
        self.pendingPermissions = pendingPermissions
        self.pendingQuestions = pendingQuestions
        self.lastFailure = lastFailure
        self.connection = connection
        self.hasLoadedTranscript = hasLoadedTranscript
        self.goal = goal
    }

    public var isBusy: Bool { status == .running }

    /// The goal still being pursued, if any — a settled goal stays in ``goal`` so a client can
    /// report the outcome, but must not present it as ongoing work.
    public var activeGoal: SessionGoal? { goal.flatMap { $0.isActive ? $0 : nil } }

    /// True while the transcript may still be on its way: nothing has been
    /// loaded yet (no cache seed, no server fetch) — distinguish this from a
    /// genuinely empty conversation before showing an empty state.
    public var isLoadingTranscript: Bool { !hasLoadedTranscript && messages.isEmpty }
}
