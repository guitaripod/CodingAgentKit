import Foundation

/// A cache that keys session lists by host rather than by backend kind.
///
/// ``SessionCache`` files sessions under an ``AgentType``, which is the right key for one server —
/// and the wrong one for several, because two machines both running opencode share that key and
/// would overwrite each other's list on every refresh. Federation therefore stores under the
/// ``ConnectionProfile`` id, which is unique per machine by construction.
///
/// Transcripts need no parallel protocol: a federated caller passes ``SessionRef/storageKey`` as
/// the session id to the existing message methods, which is already collision-free across hosts.
public protocol FederatedSessionCache: SessionCache {
    func sessions(forHost hostID: String) async -> [AgentSession]
    func store(_ sessions: [AgentSession], forHost hostID: String) async
}

extension FileSessionCache: FederatedSessionCache {
    public func sessions(forHost hostID: String) async -> [AgentSession] {
        load([AgentSession].self, from: "host-\(sanitize(hostID)).json") ?? []
    }

    public func store(_ sessions: [AgentSession], forHost hostID: String) async {
        save(sessions, to: "host-\(sanitize(hostID)).json")
    }
}

extension InMemorySessionCache: FederatedSessionCache {
    public func sessions(forHost hostID: String) async -> [AgentSession] {
        sessionsByHost[hostID] ?? []
    }

    public func store(_ sessions: [AgentSession], forHost hostID: String) async {
        sessionsByHost[hostID] = sessions
    }
}
