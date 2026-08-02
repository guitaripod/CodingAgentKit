import Foundation

/// A backend that can push session-list changes instead of being polled. Optional: callers fall
/// back to their timers when `sessionListChanges()` answers nil.
public enum SessionListChange: Sendable {
    case upsert(AgentSession)
    case remove(String)
    /// The stream lost its replay window: re-fetch the list before trusting later changes.
    case invalidated
}

public protocol SessionListStreaming: Sendable {
    func sessionListChanges() async -> AsyncStream<SessionListChange>?
}

/// A backend that can push live subagent facts for a session.
public protocol SubagentStreaming: Sendable {
    func subagentChanges(for sessionID: String) async -> AsyncStream<[SubagentSummary]>?
}
