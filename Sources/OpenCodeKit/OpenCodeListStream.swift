import AgentCore
import Foundation

/// The chat list, pushed rather than polled.
///
/// opencode keeps a turn's liveness in memory rather than in the session record, so a listing can
/// only ever describe the moment it was taken: a row that went live a second after the last fetch
/// stays settled until something asks again, and a phone has nothing that asks. The server's own
/// global stream carries the transitions — `session.status` on every loop step, `session.idle` when
/// the turn lets go — so the list follows the machine instead of the refresh button.
///
/// `/event` is scoped to one workspace; a chat list spans every project the server holds, so this
/// reads `/global/event`, whose frames wrap the payload and name the workspace it came from.
extension OpenCodeBackend: SessionListStreaming {
    private struct GlobalFrame: Decodable {
        struct Payload: Decodable {
            let type: String?
            let properties: JSONValue?
        }
        let directory: String?
        let payload: Payload
    }

    /// What the stream has said so far, so a `session.status` naming only an id can still be
    /// published as a whole row, and so a change that changes nothing a list draws is dropped
    /// rather than written through every client's cache file.
    private actor ListMemory {
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

    public func sessionListChanges() async -> AsyncStream<SessionListChange>? {
        AsyncStream { continuation in
            let task = Task {
                let memory = ListMemory()
                while !Task.isCancelled {
                    continuation.yield(.invalidated)
                    do {
                        for try await sse in client.globalEventStream() {
                            if Task.isCancelled { return }
                            for change in await self.changes(from: sse, memory: memory) {
                                continuation.yield(change)
                            }
                        }
                    } catch {
                        AgentLog.logger("opencode").debug("global event stream ended: \(error)")
                    }
                    if Task.isCancelled { return }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func changes(from event: SSEvent, memory: ListMemory) async -> [SessionListChange] {
        guard let data = event.data.data(using: .utf8),
            let frame = try? JSONCoding.decoder.decode(GlobalFrame.self, from: data),
            let type = frame.payload.type
        else { return [] }
        let properties = frame.payload.properties

        switch type {
        case "session.created", "session.updated":
            guard let info = properties?["info"], let session = Self.session(from: info) else {
                return []
            }
            await directories.record(sessionID: session.id, directory: session.directory)
            let merged = await memory.adopting(session)
            let changed = await memory.differs(merged)
            await memory.remember(merged)
            guard changed, !merged.isSubagent else { return [] }
            return [.upsert(merged)]

        case "session.deleted":
            guard let id = properties?["sessionID"]?.stringValue else { return [] }
            await memory.forget(id)
            return [.remove(id)]

        case "session.status", "session.idle":
            guard let id = properties?["sessionID"]?.stringValue else { return [] }
            let running =
                type == "session.idle"
                ? false
                : (properties?["status"]?["type"]?.stringValue).map {
                    OpenCodeMapping.isRunning(OCSessionStatus(type: $0))
                } ?? false
            if await memory.session(id) == nil {
                guard let fetched = try? await client.session(id) else { return [] }
                await memory.remember(OpenCodeMapping.session(fetched))
            }
            return await memory.setRunning(running, for: id)
                .filter { !$0.isSubagent }
                .map { .upsert($0) }

        default:
            return []
        }
    }

    private static func session(from value: JSONValue) -> AgentSession? {
        guard let data = try? JSONCoding.encoder.encode(value),
            let session = try? JSONCoding.decoder.decode(OCSession.self, from: data)
        else { return nil }
        return OpenCodeMapping.session(session)
    }
}
