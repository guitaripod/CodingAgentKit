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

    public init(
        id: String, title: String, agentType: String? = nil, toolUseID: String? = nil,
        updatedAt: Date, isActive: Bool = false, isCompleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.agentType = agentType
        self.toolUseID = toolUseID
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.isCompleted = isCompleted
    }
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
                var lastCount = -1
                var lastActive = true
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(lastActive ? 4 : 15))
                    guard !Task.isCancelled else { break }
                    let summary = (try? await base.subagents(for: parentSessionID))?
                        .first { $0.id == agentID }
                    let active = summary?.isActive ?? false
                    if active || lastCount == -1 {
                        if let messages = try? await base.subagentMessages(
                            sessionID: parentSessionID, agentID: agentID)
                        {
                            if messages.count != lastCount || active {
                                for message in messages {
                                    continuation.yield(
                                        .messageUpserted(message, replaceParts: true))
                                }
                                lastCount = messages.count
                            }
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
}
