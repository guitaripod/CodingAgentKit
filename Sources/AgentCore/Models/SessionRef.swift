import Foundation

/// Which machine a session lives on, and which session it is there.
///
/// A session's truth is not portable: it includes a working directory, a repo checkout at some
/// commit, and a toolchain, none of which another machine has. So there is no global session store
/// to move one into — each host's server is the only authority for the sessions it holds, and a
/// client that talks to several must carry the host with the id or it will eventually ask the wrong
/// machine about a session it has never heard of.
///
/// Two hosts running the same backend routinely mint the same session id, so `id` alone is not a
/// key across a federation; ``storageKey`` is.
public struct SessionRef: Sendable, Hashable, Codable, Identifiable {
    /// The ``ConnectionProfile`` id of the machine holding this session.
    public let hostID: String
    /// The session id as that host's own server reports it.
    public let sessionID: String

    public var id: String { storageKey }

    /// Stable, collision-free identity for a session across every host a client knows.
    ///
    /// Host ids are profile UUIDs and session ids are backend-minted, so neither contains the
    /// separator; splitting on the first one recovers both halves exactly.
    public var storageKey: String { "\(hostID)/\(sessionID)" }

    public init(hostID: String, sessionID: String) {
        self.hostID = hostID
        self.sessionID = sessionID
    }

    /// Rebuilds a ref from a ``storageKey``, or nil when the string was never one — a cached key
    /// written before hosts were namespaced, say, which must be discarded rather than guessed at.
    public init?(storageKey: String) {
        guard let separator = storageKey.firstIndex(of: "/") else { return nil }
        let host = String(storageKey[storageKey.startIndex..<separator])
        let session = String(storageKey[storageKey.index(after: separator)...])
        guard !host.isEmpty, !session.isEmpty else { return nil }
        self.hostID = host
        self.sessionID = session
    }
}
