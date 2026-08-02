import Foundation

/// A subagent spawned inside a session (Claude Code writes each one's
/// transcript to a sidecar file next to the session's own).
public struct SubagentSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var title: String
    public var agentType: String?
    public var toolUseID: String?
    public var updatedAt: Date
    public var isActive: Bool
    public var isCompleted: Bool
    /// What a live agent is doing right now, when the backend can say: how far through its todo
    /// list it is, how many tools it has run, and the one running at the moment.
    public var startedAt: Date?
    public var toolCount: Int?
    public var currentTool: String?
    public var todosDone: Int?
    public var todosTotal: Int?
    public var currentTodo: String?

    public init(
        id: String, title: String, agentType: String? = nil, toolUseID: String? = nil,
        updatedAt: Date, isActive: Bool = false, isCompleted: Bool = false,
        startedAt: Date? = nil, toolCount: Int? = nil, currentTool: String? = nil,
        todosDone: Int? = nil, todosTotal: Int? = nil, currentTodo: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agentType = agentType
        self.toolUseID = toolUseID
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.isCompleted = isCompleted
        self.startedAt = startedAt
        self.toolCount = toolCount
        self.currentTool = currentTool
        self.todosDone = todosDone
        self.todosTotal = todosTotal
        self.currentTodo = currentTodo
    }

    /// Fallback display title for a subagent the backend never named.
    public static var untitled: String { AgentText.string("Agent") }
}

/// Read-only view over one subagent's transcript, shaped as a backend so the
/// full conversation UI can render it unchanged. Events poll the underlying
/// backend while the subagent is active and re-emit the transcript as
/// upserts; sending is unsupported.
public struct SubagentTranscriptBackend: CodingAgentBackend {
    private let base: any CodingAgentBackend
    private let parentSessionID: String
    private let agentID: String

    public init(base: any CodingAgentBackend, parentSessionID: String, agentID: String) {
        self.base = base
        self.parentSessionID = parentSessionID
        self.agentID = agentID
    }

    public var agentType: AgentType { base.agentType }
    public var capabilities: BackendCapabilities {
        BackendCapabilities(
            supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
            supportsMultipleSessions: false, supportsModelSelection: false,
            supportsAttachments: false)
    }

    public func health() async throws -> ServerHealth { try await base.health() }
    public func listSessions() async throws -> [AgentSession] { [] }
    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        throw AgentError.unsupported("createSession")
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await base.subagentMessages(sessionID: parentSessionID, agentID: agentID)
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        throw AgentError.unsupported("send")
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let base = base
        let parentSessionID = parentSessionID
        let agentID = agentID
        return AsyncThrowingStream { continuation in
            let task = Task {
                var lastMessages: [ChatMessage]? = nil
                var lastActive = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(lastActive ? 4 : 15))
                    guard !Task.isCancelled else { break }
                    let summary = (try? await base.subagents(for: parentSessionID))?
                        .first { $0.id == agentID }
                    let active = summary?.isActive ?? false
                    if active || lastActive || lastMessages == nil {
                        if let messages = try? await base.subagentMessages(
                            sessionID: parentSessionID, agentID: agentID)
                        {
                            Self.yieldChangedMessages(
                                previous: lastMessages, current: messages, into: continuation)
                            lastMessages = messages
                        }
                    }
                    if active != lastActive {
                        continuation.yield(.status(active ? .running : .idle))
                        lastActive = active
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Upserts only messages that are new or whose content differs from the
    /// previous poll, so an unchanged transcript produces no events and
    /// subscribers never re-process the full history on every tick.
    private static func yieldChangedMessages(
        previous: [ChatMessage]?,
        current: [ChatMessage],
        into continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation
    ) {
        let previousByID = Dictionary(
            (previous ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for message in current where previousByID[message.id] != message {
            continuation.yield(.messageUpserted(message, replaceParts: true))
        }
    }
}
