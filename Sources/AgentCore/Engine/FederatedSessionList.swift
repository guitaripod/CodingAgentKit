import Foundation

/// How one host's contribution to a merged session list stands.
public struct HostReading: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// The host answered this refresh; its rows are the server's own current truth.
        case live
        /// The host did not answer and these rows are the last ones it gave, with why.
        case stale(String)
        /// The host has never answered and nothing was cached, so it contributes nothing.
        case unknown(String)
    }

    public let hostID: String
    public var state: State
    /// When these rows were last read from the host's own server, by this device's clock.
    /// Nil until the host has answered once.
    public var observedAt: Date?

    public var id: String { hostID }

    public var isLive: Bool { if case .live = state { return true } else { return false } }

    /// The instant every live-duration label for this host's rows must be measured against.
    ///
    /// A turn that was running when a host went quiet is not still running for all the time the
    /// client then spent failing to reach that machine — the laptop may have slept, the server may
    /// have been killed, the turn may have finished thirty seconds later. Counting on regardless
    /// asserts knowledge nobody has, and produces the specific lie of a card reading "running for
    /// 4h" about a turn that ended before breakfast. So a host that is not live freezes its clock
    /// at ``observedAt`` and the label reads as of that moment rather than ticking.
    public func elapsedReference(now: Date) -> Date {
        isLive ? now : (observedAt ?? now)
    }

    public init(hostID: String, state: State, observedAt: Date? = nil) {
        self.hostID = hostID
        self.state = state
        self.observedAt = observedAt
    }
}

/// One render-ready view of every host's sessions at a moment.
public struct FederatedSnapshot: Sendable {
    /// Every known host's standing, including the ones that failed — a host missing from a list is
    /// indistinguishable from a host with no sessions, and the two need different UI.
    public var readings: [HostReading]
    /// Every host's sessions merged and ordered newest-first, each stamped with its ``AgentSession/hostID``.
    public var sessions: [AgentSession]

    /// Every host answered from its own server this pass.
    public var isComplete: Bool { readings.allSatisfy(\.isLive) }

    /// Hosts whose rows are last-known rather than current, for a banner that says so.
    public var staleHosts: [HostReading] { readings.filter { !$0.isLive } }

    public func reading(forHost hostID: String) -> HostReading? {
        readings.first { $0.hostID == hostID }
    }

    /// The instant `session`'s duration labels must be measured against, given which host it came
    /// from. Falls back to `now` for a session no host claims, which is a session read directly
    /// rather than federated.
    public func elapsedReference(for session: AgentSession, now: Date) -> Date {
        guard let hostID = session.hostID, let reading = reading(forHost: hostID) else { return now }
        return reading.elapsedReference(now: now)
    }

    public init(readings: [HostReading], sessions: [AgentSession]) {
        self.readings = readings
        self.sessions = sessions
    }
}

/// Merges the session lists of every machine a client is connected to into one inbox.
///
/// Each host's server stays the sole authority for its own sessions — nothing is copied between
/// machines and no shared store is invented, because a session's truth includes a working directory
/// and a repo checkout that only its own host has. What federates is the *view*: this reads every
/// host in parallel, stamps each row with the host it came from, and orders the union by recency.
///
/// Two properties matter more than the merge itself:
///
/// - **A sleeping machine must not stall the inbox.** A tailnet peer can answer at the overlay
///   layer while its TCP ports blackhole, so a connect against a sleeping laptop does not fail
///   fast — it hangs until the transport gives up, which is minutes. Every host therefore races a
///   hard deadline and a host that misses it contributes its cached rows instead of blocking.
/// - **Cached rows must be labelled, not disguised.** A stale row is shown so the inbox stays
///   populated, but it is marked stale and its clocks freeze (``HostReading/elapsedReference(now:)``)
///   so no label claims to know what an unreachable machine is doing right now.
public actor FederatedSessionList {
    private struct Host {
        let backend: any CodingAgentBackend
        var lastGood: [AgentSession]
        var observedAt: Date?
    }

    private var hosts: [String: Host] = [:]
    private var order: [String] = []
    private let cache: (any FederatedSessionCache)?
    private let deadline: Duration
    private let knownDirectories: [String]
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - deadline: how long one host gets to answer before the pass moves on without it. Two
    ///     seconds is chosen against a human waiting on a list, not against a slow server: a host
    ///     that needs longer is a host whose rows are better served from cache this pass and live
    ///     on the next one.
    ///   - now: injectable clock, so freezing behaviour is testable without waiting.
    public init(
        cache: (any FederatedSessionCache)? = nil,
        deadline: Duration = .seconds(2),
        knownDirectories: [String] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.deadline = deadline
        self.knownDirectories = knownDirectories
        self.now = now
    }

    /// Replaces the connected set, preserving the last-known rows of hosts that survive the change
    /// so an unrelated profile edit cannot blank a reachable machine's section.
    public func setHosts(_ backends: [(hostID: String, backend: any CodingAgentBackend)]) {
        var next: [String: Host] = [:]
        for entry in backends {
            if let existing = hosts[entry.hostID] {
                next[entry.hostID] = Host(
                    backend: entry.backend,
                    lastGood: existing.lastGood,
                    observedAt: existing.observedAt)
            } else {
                next[entry.hostID] = Host(backend: entry.backend, lastGood: [], observedAt: nil)
            }
        }
        hosts = next
        order = backends.map(\.hostID)
    }

    /// The inbox as it can be drawn before any network call, from cache alone.
    ///
    /// Every reading is stale by construction here: nothing has been read from a server yet, so no
    /// clock may tick. This is what the list renders on the first frame.
    public func cachedSnapshot() async -> FederatedSnapshot {
        var readings: [HostReading] = []
        var merged: [AgentSession] = []
        for hostID in order {
            guard var host = hosts[hostID] else { continue }
            if host.lastGood.isEmpty, let cache {
                host.lastGood = await cache.sessions(forHost: hostID).map {
                    var session = $0
                    session.hostID = hostID
                    return session
                }
                hosts[hostID] = host
            }
            let state: HostReading.State =
                host.lastGood.isEmpty
                ? .unknown("not read yet") : .stale("not read yet")
            readings.append(
                HostReading(hostID: hostID, state: state, observedAt: host.observedAt))
            merged.append(contentsOf: host.lastGood)
        }
        return FederatedSnapshot(readings: readings, sessions: Self.ordered(merged))
    }

    /// Reads every host in parallel and emits the inbox as it fills in.
    ///
    /// The first element is the cached snapshot, so a caller can render immediately; each host that
    /// answers (or gives up) produces one more element with that host patched in. Callers that only
    /// want the settled list can take the last element, but the point of the stream is that a fast
    /// machine's sessions appear without waiting on a sleeping one.
    public func refresh() -> AsyncStream<FederatedSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(await self.cachedSnapshot())
                await withTaskGroup(of: (String, Result<[AgentSession], any Error>).self) { group in
                    for hostID in await self.order {
                        guard let host = await self.hosts[hostID] else { continue }
                        let backend = host.backend
                        let deadline = await self.deadline
                        let directories = await self.knownDirectories
                        group.addTask {
                            (hostID, await Self.read(backend, directories, deadline))
                        }
                    }
                    for await (hostID, result) in group {
                        await self.apply(result, forHost: hostID)
                        continuation.yield(await self.currentSnapshot())
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The inbox from what every host has most recently given, without reading anything.
    public func currentSnapshot() -> FederatedSnapshot {
        var readings: [HostReading] = []
        var merged: [AgentSession] = []
        for hostID in order {
            guard let host = hosts[hostID] else { continue }
            readings.append(
                HostReading(hostID: hostID, state: state(for: hostID), observedAt: host.observedAt))
            merged.append(contentsOf: host.lastGood)
        }
        return FederatedSnapshot(readings: readings, sessions: Self.ordered(merged))
    }

    private var states: [String: HostReading.State] = [:]

    private func state(for hostID: String) -> HostReading.State {
        states[hostID] ?? (hosts[hostID]?.lastGood.isEmpty == false
            ? .stale("not read yet") : .unknown("not read yet"))
    }

    private func apply(_ result: Result<[AgentSession], any Error>, forHost hostID: String) async {
        guard var host = hosts[hostID] else { return }
        switch result {
        case .success(let sessions):
            let stamped = sessions.map { session -> AgentSession in
                var copy = session
                copy.hostID = hostID
                return copy
            }
            host.lastGood = stamped
            host.observedAt = now()
            hosts[hostID] = host
            states[hostID] = .live
            await cache?.store(stamped, forHost: hostID)
        case .failure(let error):
            states[hostID] =
                host.lastGood.isEmpty
                ? .unknown(Self.reason(error)) : .stale(Self.reason(error))
        }
    }

    /// Races the host's listing against the deadline so a blackholed peer costs one deadline rather
    /// than one transport timeout. The loser is cancelled, so a late answer never lands after the
    /// pass that gave up on it.
    private static func read(
        _ backend: any CodingAgentBackend,
        _ directories: [String],
        _ deadline: Duration
    ) async -> Result<[AgentSession], any Error> {
        await withTaskGroup(of: Result<[AgentSession], any Error>?.self) { group in
            group.addTask {
                do { return .success(try await backend.listAllSessions(knownDirectories: directories)) }
                catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return Task.isCancelled ? nil : .failure(AgentError.unsupported("host did not answer in time"))
            }
            for await result in group {
                guard let result else { continue }
                group.cancelAll()
                return result
            }
            return .failure(AgentError.unsupported("host did not answer"))
        }
    }

    private static func reason(_ error: any Error) -> String {
        (error as? AgentError).map(String.init(describing:)) ?? error.localizedDescription
    }

    /// Newest first, with ties broken on the host-scoped key so the order of two sessions stamped
    /// the same second is stable between refreshes instead of flickering.
    private static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted {
            $0.updatedAt == $1.updatedAt
                ? ($0.ref?.storageKey ?? $0.id) < ($1.ref?.storageKey ?? $1.id)
                : $0.updatedAt > $1.updatedAt
        }
    }
}
