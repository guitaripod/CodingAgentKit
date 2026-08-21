import Foundation

/// How long a session has been working, and whether that number is still moving.
///
/// Every duration a client draws is a claim about a machine it is not on, so the claim has to carry
/// its own confidence. Three failures come from drawing elapsed time as a plain interval:
///
/// - A host that stopped answering keeps counting, so a turn that ended hours ago reads as still
///   running. The count must freeze at the last reading and say so.
/// - Two machines' clocks disagree, so a session stamped a few seconds in the device's future reads
///   as negative. Skew is not information; it clamps to zero.
/// - An idle session is given a running label because the row it sits in has a duration field at
///   all. Idle sessions have a *last activity*, which is a different sentence.
public enum LiveDuration: Sendable, Hashable {
    /// Work is in flight and the host is answering: this number is moving.
    case running(since: Date, measuredAt: Date)
    /// Work was in flight when the host was last read, and it has not been read since. The number
    /// is what it was then and must be presented as a reading, not a stopwatch.
    case frozen(since: Date, observedAt: Date)
    /// Nothing is running; the session was last written to at this instant.
    case idle(lastActivity: Date)
    /// Nothing is known — a host that has never answered and had nothing cached.
    case unknown

    /// The elapsed seconds to draw, never negative. Nil when there is nothing to draw.
    public var seconds: TimeInterval? {
        switch self {
        case .running(let since, let measuredAt): max(0, measuredAt.timeIntervalSince(since))
        case .frozen(let since, let observedAt): max(0, observedAt.timeIntervalSince(since))
        case .idle, .unknown: nil
        }
    }

    /// Whether a view may drive this from a repeating timer. A frozen or idle duration redrawn on a
    /// tick is the bug this type exists to prevent.
    public var isTicking: Bool { if case .running = self { true } else { false } }

    /// Builds the duration for one session as seen through a snapshot, which knows whether the
    /// session's host is currently answering.
    ///
    /// `startedAt` is when the running turn began. Backends that do not report a turn start pass
    /// nil and fall back to the session's own last write, which is the best available floor: a
    /// session being written to right now started its current turn no earlier than that.
    public static func of(
        _ session: AgentSession,
        in snapshot: FederatedSnapshot,
        startedAt: Date? = nil,
        now: Date
    ) -> LiveDuration {
        let hostIsLive = session.hostID.flatMap { snapshot.reading(forHost: $0) }?.isLive ?? true
        let reference = snapshot.elapsedReference(for: session, now: now)
        guard session.isWorking else { return .idle(lastActivity: session.updatedAt) }
        let since = startedAt ?? session.updatedAt
        if hostIsLive { return .running(since: since, measuredAt: reference) }
        guard let observedAt = session.hostID.flatMap({ snapshot.reading(forHost: $0) })?.observedAt
        else { return .unknown }
        return .frozen(since: since, observedAt: observedAt)
    }

    /// Compact elapsed text — `12s`, `4m 12s`, `2h 04m` — or nil when there is nothing to draw.
    /// Hours drop seconds because a label that changes every second at that scale only asks the eye
    /// to re-read a number that has not meaningfully moved.
    public var elapsedText: String? {
        guard let seconds, seconds.isFinite else { return nil }
        let total = Int(seconds)
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(String(format: "%02d", total % 60))s" }
        return "\(total / 3600)h \(String(format: "%02d", (total % 3600) / 60))m"
    }
}
