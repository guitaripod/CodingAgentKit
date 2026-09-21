import AgentCore
import Foundation

/// What the stream has said so far, so a `session.status` naming only an id can still be
/// published as a whole row, and so a change that changes nothing a list draws is dropped
/// rather than written through every client's cache file.
actor OpenCodeListMemory {
    private var sessions: [String: AgentSession] = [:]

    func remember(_ session: AgentSession) { sessions[session.id] = session }

    func session(_ id: String) -> AgentSession? { sessions[id] }

    /// The rows a liveness transition actually moved, plus the parent recounted when the id
    /// names a spawned agent — a parent whose own turn is closed while its agents work is
    /// working. `busy` is republished on every loop step, so a status that says what the last
    /// one said moves nothing and is dropped here rather than written through every client's
    /// cache file a dozen times a turn.
    func setRunning(_ running: Bool, for id: String) -> [AgentSession] {
        guard var session = sessions[id], session.isActive != running else { return [] }
        session.isActive = running
        sessions[id] = session
        var changed = [session]
        if let parentID = session.parentID, var parent = sessions[parentID] {
            let count = sessions.values.filter {
                $0.parentID == parentID && $0.isActive == true
            }.count
            let recounted = count > 0 ? count : nil
            if parent.activeAgents != recounted {
                parent.activeAgents = recounted
                sessions[parentID] = parent
                changed.append(parent)
            }
        }
        return changed
    }

    /// A record the server re-published keeps whatever the status frames have established:
    /// `session.updated` carries no liveness, and adopting its silence would settle a row the
    /// stream just said was busy.
    func adopting(_ fresh: AgentSession) -> AgentSession {
        var fresh = fresh
        if let known = sessions[fresh.id] {
            fresh.isActive = known.isActive
            fresh.activeAgents = known.activeAgents
        }
        return fresh
    }

    func forget(_ id: String) { sessions[id] = nil }

    func differs(_ session: AgentSession) -> Bool {
        guard let known = sessions[session.id] else { return true }
        return known.isActive != session.isActive
            || known.activeAgents != session.activeAgents
            || known.title != session.title
            || known.updatedAt != session.updatedAt
    }
}
