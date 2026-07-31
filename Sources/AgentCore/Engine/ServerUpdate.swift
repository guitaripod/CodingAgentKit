import Foundation

/// What a server says about its own version, and about the newer one it could move to.
///
/// A server reached over a tailnet from a phone is a machine the person holding the phone often
/// cannot open a terminal on. So the update is something the server offers and the client asks
/// for, rather than a command someone has to remember to run.
public struct ServerUpdate: Sendable, Hashable, Codable {
    /// Phases a running update passes through. Reported by the server so a client can say what is
    /// happening rather than spinning blindly through a restart.
    public enum Phase: String, Sendable, Hashable, Codable {
        case idle
        case running
        case building
        case restarting
        case succeeded
        case failed
    }

    public var version: String
    public var commit: String?
    public var latestVersion: String?
    public var latestCommit: String?
    public var updateAvailable: Bool
    /// How many commits this install is behind, when the server can tell.
    public var behind: Int?
    /// Subjects of the commits an update would bring in, newest first.
    public var changes: [String]
    public var canUpdate: Bool
    /// Why the server cannot update itself, in words worth showing a person.
    public var reason: String?
    /// What supervises the server: `systemd`, `launchd`, or `manual`.
    public var manager: String
    public var source: String?
    public var phase: Phase
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Tail of the update's own log, for when it fails.
    public var log: String?

    public init(
        version: String, commit: String? = nil, latestVersion: String? = nil,
        latestCommit: String? = nil, updateAvailable: Bool = false, behind: Int? = nil,
        changes: [String] = [], canUpdate: Bool = false, reason: String? = nil,
        manager: String = "manual", source: String? = nil, phase: Phase = .idle,
        startedAt: Date? = nil, finishedAt: Date? = nil, log: String? = nil
    ) {
        self.version = version
        self.commit = commit
        self.latestVersion = latestVersion
        self.latestCommit = latestCommit
        self.updateAvailable = updateAvailable
        self.behind = behind
        self.changes = changes
        self.canUpdate = canUpdate
        self.reason = reason
        self.manager = manager
        self.source = source
        self.phase = phase
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.log = log
    }

    /// True while the server is working through an update it accepted — including the stretch where
    /// it is restarting and answering nothing at all.
    public var isRunning: Bool {
        phase == .running || phase == .building || phase == .restarting
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
        commit = try container.decodeIfPresent(String.self, forKey: .commit)
        latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
        latestCommit = try container.decodeIfPresent(String.self, forKey: .latestCommit)
        updateAvailable =
            try container.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        behind = try container.decodeIfPresent(Int.self, forKey: .behind)
        changes = try container.decodeIfPresent([String].self, forKey: .changes) ?? []
        canUpdate = try container.decodeIfPresent(Bool.self, forKey: .canUpdate) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        manager = try container.decodeIfPresent(String.self, forKey: .manager) ?? "manual"
        source = try container.decodeIfPresent(String.self, forKey: .source)
        phase = try container.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        log = try container.decodeIfPresent(String.self, forKey: .log)
    }
}

/// A backend whose server can install its own updates.
///
/// Conformance is not the same as ability: an old server that has never heard of the route throws
/// ``AgentError/unsupported(_:)``, and a server that cannot update itself says so in
/// ``ServerUpdate/reason``.
public protocol SelfUpdatingBackend: CodingAgentBackend {
    /// The server's version and, unless `checkingRemote` is false, whether a newer one exists.
    /// Checking the remote costs the server a network round trip, so a client polling an update in
    /// flight should pass false.
    func updateStatus(checkingRemote: Bool) async throws -> ServerUpdate
    /// Asks the server to update itself. Returns as soon as the work has been handed off; the
    /// server will stop answering for a moment when it restarts.
    func startUpdate() async throws -> ServerUpdate
}
