import AgentCore
import Foundation

/// One multiplexed connection to a proto-2 bridge, shared by every conversation and list view on
/// that server. Owns the socket, the `epoch:seq` cursor, reconnection with replay, a heartbeat
/// watchdog, and per-session fan-out. The contract it enforces: a subscriber either receives a
/// contiguous run of the bridge's log, or is told to re-read (``BackendEvent/resync``) — silence
/// is never a lie, a gap is never invisible.
///
/// A subscription is never ended by the socket. The socket belongs to every conversation on the
/// server at once, and ending each one's stream whenever it dropped sent every conversation off to
/// re-read and re-subscribe on its own clock, into a window between the two that nothing covered:
/// a turn end published in that window reached nobody, and the conversation stayed busy for good.
/// So the socket's state travels as events inside the subscription instead — ``detached`` while it
/// is being dialled again, ``attached`` when it proves itself, ``resync`` when the bridge could not
/// replay what was missed — and the one thing that ends a subscription is a refusal that a redial
/// cannot cure.
actor BridgeStream {
    enum ListChange: Sendable {
        case upsert(AgentSession)
        case remove(String)
        /// The replay window was lost (restart, eviction): anything rendered from this stream
        /// must be re-fetched before it can be trusted again.
        case invalidated
    }

    private let builder: RequestBuilder
    private let http: HTTPClient
    nonisolated(unsafe) var agentType: AgentType = .claudeCode

    private var proto: Int?
    private var probedAt = Date.distantPast
    private var cursor: (epoch: String, seq: UInt64)?
    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var lastFrameAt = Date.distantPast
    /// Whether the socket has spoken since it was last dialled. Set by the first frame off a
    /// connection and cleared the moment the connection ends, so it is never true of a dial that
    /// is still in progress.
    private var connected = false
    private var lastRedialAt = Date.distantPast

    /// The bridge heartbeats every ten seconds. A socket that has said nothing for longer than
    /// two and a half of them is not believed to be open, whatever the transport thinks.
    private static let freshWindow: TimeInterval = 25
    /// How long a proven-silent socket is left to the watchdog before an arriving subscriber is
    /// allowed to hurry it along. The watchdog is the ceiling, this is the floor.
    private static let redialGap: TimeInterval = 2

    /// A socket that has proved itself recently enough to be trusted with a subscriber's
    /// "connected" reading.
    private var isFresh: Bool {
        connected && Date().timeIntervalSince(lastFrameAt) < Self.freshWindow
    }

    private var sessionSubs: [String: [UUID: AsyncThrowingStream<BackendEvent, Error>.Continuation]] = [:]
    private var sessionDecoders: [String: BridgeEventDecoder] = [:]
    private var listSubs: [UUID: AsyncStream<ListChange>.Continuation] = [:]
    private var agentSubs: [String: [UUID: AsyncStream<[SubagentSummary]>.Continuation]] = [:]

    init(builder: RequestBuilder, http: HTTPClient) {
        self.builder = builder
        self.http = http
    }

    /// Whether the server speaks proto 2. A yes is cached for the process; a no is re-asked
    /// after a minute — a bridge upgraded mid-flight must reach running apps without a relaunch.
    func supportsStream() async -> Bool {
        if let proto, proto >= 2 { return true }
        if proto != nil, Date().timeIntervalSince(probedAt) < 60 { return false }
        probedAt = Date()
        guard let data = try? await http.send(builder.request(.get, "/status")),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            proto = 1
            return false
        }
        proto = object["proto"] as? Int ?? 1
        return (proto ?? 1) >= 2
    }

    func sessionEvents(_ sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task { await self.addSessionSub(sessionID, id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeSessionSub(sessionID, id: id) }
            }
        }
    }

    func listEvents() -> AsyncStream<ListChange> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addListSub(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeListSub(id: id) }
            }
        }
    }

    func agentEvents(_ sessionID: String) -> AsyncStream<[SubagentSummary]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addAgentSub(sessionID, id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeAgentSub(sessionID, id: id) }
            }
        }
    }

    private func addSessionSub(
        _ sessionID: String, id: UUID,
        continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation
    ) {
        sessionSubs[sessionID, default: [:]][id] = continuation
        // A conversation opened onto a socket that is already up hears no hello of its own — the
        // hello was somebody else's. Without this it would wait for the next heartbeat to learn
        // it is connected, which on a quiet server is the difference between "ready" and
        // "connecting" for a minute. Only a socket that has spoken recently is vouched for: one
        // that is dialling, or has gone quiet past its heartbeats, is exactly what a phone back
        // from its pocket is holding, and calling that "live" is the lie this event exists to end.
        if isFresh { continuation.yield(.attached) }
        let wasDialling = connectionTask != nil
        ensureRunning()
        if wasDialling { redialIfStale() }
    }

    /// Dials again now on a socket nobody has heard from past the bridge's heartbeats.
    ///
    /// The watchdog inside the connection notices the same silence on its own interval, and a
    /// transport whose socket a suspension killed underneath it may take the whole read timeout
    /// to say so. A subscriber arriving is a reason not to wait: it is a conversation being opened
    /// or a phone coming back, and the first thing either wants is a socket that is actually open.
    /// Rate-limited so a burst of subscribers on the same wake dials once.
    private func redialIfStale() {
        guard connectionTask != nil, cursor != nil, !isFresh,
            Date().timeIntervalSince(lastFrameAt) > Self.freshWindow,
            Date().timeIntervalSince(lastRedialAt) > Self.redialGap
        else { return }
        lastRedialAt = Date()
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
        ensureRunning()
    }

    private func removeSessionSub(_ sessionID: String, id: UUID) {
        sessionSubs[sessionID]?[id] = nil
        if sessionSubs[sessionID]?.isEmpty == true { sessionSubs[sessionID] = nil }
        stopIfUnobserved()
    }

    private func addListSub(id: UUID, continuation: AsyncStream<ListChange>.Continuation) {
        listSubs[id] = continuation
        ensureRunning()
    }

    private func removeListSub(id: UUID) {
        listSubs[id] = nil
        stopIfUnobserved()
    }

    private func addAgentSub(
        _ sessionID: String, id: UUID, continuation: AsyncStream<[SubagentSummary]>.Continuation
    ) {
        agentSubs[sessionID, default: [:]][id] = continuation
        ensureRunning()
    }

    private func removeAgentSub(_ sessionID: String, id: UUID) {
        agentSubs[sessionID]?[id] = nil
        if agentSubs[sessionID]?.isEmpty == true { agentSubs[sessionID] = nil }
        stopIfUnobserved()
    }

    private func stopIfUnobserved() {
        guard sessionSubs.isEmpty, listSubs.isEmpty, agentSubs.isEmpty else { return }
        connectionGeneration += 1
        connectionTask?.cancel()
        connectionTask = nil
    }

    private func ensureRunning() {
        guard connectionTask == nil else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionTask = Task { await self.runLoop(generation: generation) }
    }

    /// A run loop that returned — every subscriber failed away and the loop's own guard saw
    /// nothing left to serve — must not leave its finished task where `ensureRunning` guards on
    /// nil. Kept, the stale handle makes every later subscription on this server wait on a
    /// connection nobody dials, forever, and only an app restart recovers. A subscriber that
    /// raced in between the loop's exit and this cleanup gets the redial immediately.
    private func clearConnectionTask(generation: Int) {
        guard generation == connectionGeneration else { return }
        connectionTask = nil
        if !sessionSubs.isEmpty || !listSubs.isEmpty || !agentSubs.isEmpty { ensureRunning() }
    }

    /// Dials until cancelled. A connection that ends is dialled again with its cursor, so the
    /// bridge replays what was missed and no subscriber has to be told anything but that the
    /// socket went and came back; the backoff grows with consecutive failures and resets the
    /// moment a hello lands. Only a refusal a redial cannot cure — a password the bridge no longer
    /// takes, a route it does not have — ends the subscriptions, because dialling into that
    /// forever would be silence dressed as reconnecting.
    private func runLoop(generation: Int) async {
        defer { clearConnectionTask(generation: generation) }
        while !Task.isCancelled {
            guard !sessionSubs.isEmpty || !listSubs.isEmpty || !agentSubs.isEmpty else { return }
            do {
                try await connectOnce(generation: generation)
            } catch is CancellationError {
                return
            } catch {
                connected = false
                failures += 1
                if let refusal = error as? AgentError, !refusal.isRetryable {
                    failSessionSubs(refusal)
                    invalidateListSubs()
                } else {
                    notifyDetached()
                }
            }
            let delay = min(10.0, 0.5 * pow(2, Double(min(failures, 5))))
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Consecutive dials that ended without a hello. Kept on the actor rather than the loop so a
    /// redial hurried along by a subscriber inherits the backoff it was in.
    private var failures = 0

    /// One connection, dialled from the cursor and read until it ends. Every frame it delivers
    /// is stamped with the generation it belongs to: a redial cancels the connection before it,
    /// but cancellation is cooperative and the old socket can still hand over frames it had
    /// already read — after the new dial's cursor was taken. Let through, those frames advanced
    /// the cursor past what the new connection was about to replay, so the replay read as a gap,
    /// and everything replayed after the gap was dispatched a second time: an answer that
    /// doubled on the screen until a refetch put it right.
    private func connectOnce(generation: Int) async throws {
        var query: [URLQueryItem] = []
        if let cursor {
            query.append(URLQueryItem(name: "since", value: "\(cursor.epoch):\(cursor.seq)"))
        }
        let request = try builder.eventStreamRequest("/stream", query: query)
        lastFrameAt = Date()
        connected = false

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await sse in self.http.serverSentEvents(request) {
                    await self.handle(sse, generation: generation)
                }
                throw AgentError.connection("stream ended")
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(12))
                    if await Date().timeIntervalSince(self.lastFrameAt) > 35 {
                        throw AgentError.connection("stream heartbeat lost")
                    }
                }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func handle(_ sse: SSEvent, generation: Int) {
        guard generation == connectionGeneration else { return }
        lastFrameAt = Date()
        connected = true
        guard let type = sse.type,
            let data = sse.data.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        switch type {
        case "hello":
            failures = 0
            let epoch = object["epoch"] as? String ?? ""
            let head = (object["seq"] as? NSNumber)?.uint64Value ?? 0
            let reset = object["reset"] as? Bool ?? false
            if let cursor, cursor.epoch == epoch, !reset {
                notifyAttached()
                break
            }
            let hadCursor = cursor != nil
            cursor = (epoch, head)
            if hadCursor || reset {
                // The replay window is gone — a restarted bridge, a cursor that fell off the
                // ring: whatever was missed is missed, and the transcript is the only account.
                notifyResync()
                invalidateListSubs()
            }
            notifyAttached()
        case "heartbeat":
            // The socket proving itself is the only thing an idle conversation ever hears. It is
            // what tells a client it is connected rather than still connecting.
            notifyAttached()
        default:
            if let id = sse.id {
                let parts = id.split(separator: ":", maxSplits: 1)
                if parts.count == 2, let seq = UInt64(parts[1]) {
                    if let cursor, String(parts[0]) == cursor.epoch, seq != cursor.seq &+ 1 {
                        // A frame arrived out of order or past a hole the server dropped: every
                        // subscriber re-reads rather than rendering around an invisible gap, and
                        // keeps listening from here, where the log is contiguous again.
                        self.cursor = (cursor.epoch, seq)
                        notifyResync()
                        invalidateListSubs()
                        return
                    }
                    cursor = (cursor?.epoch ?? String(parts[0]), seq)
                }
            }
            dispatch(type: type, object: object)
        }
    }

    private func dispatch(type: String, object: [String: Any]) {
        switch type {
        case "session":
            guard let sessionID = object["session"] as? String,
                let subs = sessionSubs[sessionID], !subs.isEmpty,
                let inner = object["event"],
                let innerData = try? JSONSerialization.data(withJSONObject: inner),
                let innerJSON = String(data: innerData, encoding: .utf8)
            else { return }
            var decoder = sessionDecoders[sessionID] ?? BridgeEventDecoder()
            let event = decoder.decode(SSEvent(id: nil, type: nil, data: innerJSON))
            sessionDecoders[sessionID] = decoder
            guard let event else { return }
            for continuation in subs.values { continuation.yield(event) }
        case "list.upsert":
            guard let data = try? JSONSerialization.data(withJSONObject: object),
                let summary = try? BridgeCoding.decoder.decode(BRSummary.self, from: data)
            else { return }
            for continuation in listSubs.values {
                continuation.yield(.upsert(summary.session(agentType: agentType)))
            }
        case "list.remove":
            guard let id = object["id"] as? String else { return }
            for continuation in listSubs.values { continuation.yield(.remove(id)) }
        case "agents":
            guard let sessionID = object["session"] as? String,
                let subs = agentSubs[sessionID], !subs.isEmpty,
                let agentsObject = object["agents"],
                let data = try? JSONSerialization.data(withJSONObject: agentsObject),
                let agents = try? BridgeCoding.decoder.decode([BRSubagent].self, from: data)
            else { return }
            let summaries = agents.map(\.summary)
            for continuation in subs.values { continuation.yield(summaries) }
        default:
            break
        }
    }

    /// Tells every session watching this server that the socket is open and current. Cheap and
    /// idempotent by design — a consumer that is already live ignores it — because the honest
    /// signal is "the transport proved itself just now", and that is worth repeating on every
    /// heartbeat rather than being inferred from the last thing anyone said.
    private func notifyAttached() {
        for subs in sessionSubs.values {
            for continuation in subs.values { continuation.yield(.attached) }
        }
    }

    /// Tells every session watching this server that the socket has gone and is being dialled
    /// again. Nothing is dropped: the cursor stands, the bridge replays on the way back, and a
    /// subscriber only has to say "reconnecting" until then.
    private func notifyDetached() {
        for subs in sessionSubs.values {
            for continuation in subs.values { continuation.yield(.detached) }
        }
    }

    /// Tells every session watching this server that frames were lost for good and the transcript
    /// has to be re-read. The subscriptions stay: they re-read in place, holding what streams
    /// meanwhile, which is the one arrangement with no window in it.
    private func notifyResync() {
        sessionDecoders = [:]
        for subs in sessionSubs.values {
            for continuation in subs.values { continuation.yield(.resync) }
        }
    }

    private func failSessionSubs(_ error: Error) {
        let all = sessionSubs
        sessionSubs = [:]
        sessionDecoders = [:]
        for subs in all.values {
            for continuation in subs.values { continuation.finish(throwing: error) }
        }
    }

    private func invalidateListSubs() {
        for continuation in listSubs.values { continuation.yield(.invalidated) }
    }
}


/// One stream per server for the whole process: backends are value types minted freely, and each
/// mint must not cost a socket. Keyed by base URL plus credentials.
enum BridgeStreamRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var streams: [String: BridgeStream] = [:]

    static func stream(config: ServerConfig, builder: RequestBuilder, http: HTTPClient)
        -> BridgeStream
    {
        let key = config.baseURL.absoluteString + "|" + (config.credentials?.username ?? "")
            + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = streams[key] { return existing }
            let created = BridgeStream(builder: builder, http: http)
            streams[key] = created
            return created
        }
    }
}
