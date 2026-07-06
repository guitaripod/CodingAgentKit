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
    public var lastFailure: BackendFailure?
    public var connection: ConnectionPhase

    public init(
        messages: [ChatMessage] = [],
        status: BackendStatus = .unknown,
        pendingPermissions: [PermissionRequest] = [],
        lastFailure: BackendFailure? = nil,
        connection: ConnectionPhase = .connecting
    ) {
        self.messages = messages
        self.status = status
        self.pendingPermissions = pendingPermissions
        self.lastFailure = lastFailure
        self.connection = connection
    }

    public var isBusy: Bool { status == .running }
}
