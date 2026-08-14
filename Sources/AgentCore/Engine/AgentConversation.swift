import Foundation

public actor AgentConversation {
    public let backend: any CodingAgentBackend
    public let sessionID: String

    private let policy: ConnectionPolicy
    private let cache: SessionCache?

    private var reducer: MessageReducer
    private var status: BackendStatus = .unknown
    private var pendingPermissions: [PermissionRequest] = []
    private var pendingQuestions: [QuestionRequest] = []
    private var transcriptQuestions: [QuestionRequest] = []
    private var resolvedQuestionIDs: Set<String> = []
    private var lastFailure: BackendFailure?
    private var connection: ConnectionPhase = .connecting
    private var connectionChangedAt = Date()
    private var loadedTranscript = false
    private var goal: SessionGoal?
    private var compaction: CompactionActivity?
    private var interruption: TurnInterruption?

    private var streamTask: Task<Void, Never>?
    private var persistTask: Task<Void, Never>?
    private var lastStreamPersist = Date.distantPast
    private var subscribers: [UUID: AsyncStream<ConversationState>.Continuation] = [:]
    private var generation = 0
    private var resolvedPermissionIDs: Set<String> = []

    private var refreshInFlight = false
    private var bufferedEvents: [BackendEvent] = []
    private var refreshChain: Task<Error?, Never>?
    private var recoveryRefreshInFlight = false
    private var droppedDeltaDuringRecovery = false
    private var reachedTerminal = false
    private var lastEventAt = Date()

    private static let maxRecoveryRefreshPasses = 3
    private static let staleTurnThreshold: TimeInterval = 45
    private static let staleTurnCheckInterval: Duration = .seconds(15)

    public init(
        backend: any CodingAgentBackend,
        sessionID: String,
        seed: [ChatMessage] = [],
        policy: ConnectionPolicy = .default,
        cache: SessionCache? = nil
    ) {
        self.backend = backend
        self.sessionID = sessionID
        self.policy = policy
        self.cache = cache
        self.reducer = MessageReducer(agentType: backend.agentType, messages: seed)
        self.loadedTranscript = !seed.isEmpty
    }

    public var messages: [ChatMessage] { reducer.snapshot }

    public var state: ConversationState {
        ConversationState(
            messages: reducer.snapshot,
            status: status,
            pendingPermissions: pendingPermissions,
            pendingQuestions: openQuestions,
            lastFailure: lastFailure,
            connection: connection,
            hasLoadedTranscript: loadedTranscript,
            goal: goal,
            compaction: compaction,
            interruption: interruption,
            connectionChangedAt: connectionChangedAt
        )
    }

    /// A stream of full conversation snapshots, updated as events arrive and the connection
    /// changes. Auto-reconnects with backoff.
    ///
    /// Every caller gets its own stream over one shared connection: a desktop window, a second
    /// window on the same session, and a session list can all observe at once, and the backend
    /// sees one subscriber. The run loop starts with the first observer and stops with the last.
    /// Calling this again is no longer how a client forces a reconnect — see ``reconnect()``.
    public func states() -> AsyncStream<ConversationState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ConversationState.self, bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        startStreamIfNeeded()
        return stream
    }

    /// Drops one observer, tearing the connection down only when the last one leaves — otherwise
    /// closing a second window would end the first window's stream.
    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
        guard subscribers.isEmpty else { return }
        stop()
    }

    private func startStreamIfNeeded() {
        guard streamTask == nil else { return }
        bumpGeneration()
        let currentGeneration = generation
        streamTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
    }

    /// A run loop that returned must not leave its finished task looking like a live
    /// subscription — `startStreamIfNeeded` guards on `streamTask == nil`, so a terminal failure
    /// that kept the stale handle would make every later ``states()`` call subscribe to a stream
    /// nothing feeds, forever. Clearing it lets the next observer dial fresh; an observer that
    /// raced in between the finish and this cleanup gets the redial immediately.
    private func clearStreamTask(generation gen: Int) {
        guard gen == generation else { return }
        streamTask = nil
        if !subscribers.isEmpty { startStreamIfNeeded() }
    }

    /// Drops the current connection and dials again immediately, without disturbing any observer.
    ///
    /// A suspended app resumes holding a socket that looks alive and delivers nothing, so coming
    /// back to the foreground has to force a fresh stream. That used to be a side effect of calling
    /// ``states()`` a second time; now that a second call is a second observer, the reconnect has
    /// to be asked for.
    public func reconnect() {
        guard !subscribers.isEmpty else { return }
        bumpGeneration()
        let currentGeneration = generation
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            await self?.runLoop(generation: currentGeneration)
        }
    }

    /// Moves to a new generation and abandons the refetches queued behind the old one.
    ///
    /// A refetch answers a question about the stream that asked for it, and a generation bump means
    /// that stream is gone. Left in the chain, the superseded refetch is worse than useless: the new
    /// run loop's own initial refresh queues behind a request nobody is cancelling, which can run to
    /// the policy's request timeout, and every event of the freshly dialled stream is held back for
    /// that whole window — the transcript sits at the old text and then arrives in one burst, which
    /// a client's reveal adopts whole rather than plays out.
    private func bumpGeneration() {
        generation += 1
        refreshChain?.cancel()
        refreshChain = nil
    }

    /// Whether anything is currently observing — a supervisor uses this to decide when a session
    /// may be released.
    public var hasObservers: Bool { !subscribers.isEmpty }

    /// A new prompt starts a fresh turn, so the previous turn's failure is no
    /// longer current state — without this, one failed turn leaves a sticky
    /// `lastFailure` that clients re-surface after every later success.
    public func send(
        _ text: String,
        model: ModelSelection? = nil,
        reasoningEffort: String? = nil,
        agent: String? = nil,
        attachments: [PromptAttachment] = []
    ) async throws {
        lastFailure = nil
        forgetFinishedCompaction()
        try await backend.send(
            SendPrompt(
                text: text, model: model, reasoningEffort: reasoningEffort, agent: agent,
                attachments: attachments),
            to: sessionID)
        // prompt_async returns before the turn streams. Mark busy so a dead event stream still
        // trips the stale-turn refresh (which re-reads the transcript) instead of sitting idle
        // forever while the server works.
        status = .running
        emit()
    }

    /// A new prompt ends the *last* compaction's standing, never a running one. Compacting is
    /// minutes of work on the server and a prompt sent meanwhile is queued behind it rather than
    /// replacing it, so dropping the activity wholesale took the "compacting" surface off screen
    /// the moment someone queued a message — while the machine was still compacting, with nothing
    /// left to say so and no event coming until it finished. Only an attempt that is over — a
    /// failure the reader has already been shown — stops being current state here.
    private func forgetFinishedCompaction() {
        guard compaction?.isRunning != true else { return }
        compaction = nil
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await backend.respond(to: permission, decision: decision)
        resolvedPermissionIDs.insert(permission.id)
        pendingPermissions.removeAll { $0.id == permission.id }
        emit()
    }

    public func cancelCurrentTurn() async throws {
        try await backend.abort(sessionID: sessionID)
    }

    /// Runs a server-side slash command. Like ``send(_:model:reasoningEffort:agent:attachments:)``
    /// this starts a fresh turn, so a previous failure stops being current state and the run
    /// carries the same model, effort and agent a typed message would. Unlike a send it does not
    /// mark the conversation busy: a backend with a command endpoint dispatches without waiting
    /// for the server to accept it, so a turn is only claimed once the server's own stream says
    /// one started — which it does within a frame of the dispatch landing.
    public func run(
        _ command: AgentCommand,
        arguments: String? = nil,
        model: ModelSelection? = nil,
        reasoningEffort: String? = nil,
        agent: String? = nil
    ) async throws {
        lastFailure = nil
        forgetFinishedCompaction()
        try await backend.runCommand(
            CommandRun(
                command: command, arguments: arguments, model: model,
                reasoningEffort: reasoningEffort, agent: agent),
            in: sessionID)
        emit()
    }

    /// Replaces the conversation so far with a summary of it, freeing the context window.
    /// `instructions` steers what the summary must keep. The transcript is untouched — only what
    /// the agent carries forward changes — and the backend reports the boundary it left behind as
    /// a ``Compaction`` part in the transcript.
    public func compact(
        instructions: String? = nil, model: ModelSelection? = nil, reasoningEffort: String? = nil
    ) async throws {
        let trimmed = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await run(
            AgentCommand(name: "compact", details: "", source: .builtin),
            arguments: (trimmed?.isEmpty ?? true) ? nil : trimmed, model: model,
            reasoningEffort: reasoningEffort)
    }

    /// Sets the standing goal. The agent acknowledges it and starts working immediately, so this
    /// is a turn like any other.
    public func setGoal(
        _ condition: String, model: ModelSelection? = nil, reasoningEffort: String? = nil
    ) async throws {
        try await run(
            AgentCommand(name: "goal", details: "", source: .builtin), arguments: condition,
            model: model, reasoningEffort: reasoningEffort)
    }

    /// Abandons the standing goal early. A goal that has been met clears itself.
    public func clearGoal(
        model: ModelSelection? = nil, reasoningEffort: String? = nil
    ) async throws {
        try await run(
            AgentCommand(name: "goal", details: "", source: .builtin), arguments: "clear",
            model: model, reasoningEffort: reasoningEffort)
    }

    public func answer(_ question: QuestionRequest, answers: [[String]]) async throws {
        try await backend.answerQuestion(question, answers: answers)
        resolve(question)
    }

    public func reject(_ question: QuestionRequest) async throws {
        try await backend.rejectQuestion(question)
        resolve(question)
    }

    /// Settles a question the client answered on its own — a backend whose
    /// ``BackendCapabilities/answersQuestionsByMessage`` is set is answered by
    /// the ordinary send path, so the card must stop asking without a second,
    /// unqueued message going out behind it.
    public func markAnswered(_ question: QuestionRequest) {
        resolve(question)
    }

    /// A question read out of the transcript stays in the transcript — an ask
    /// answered from here is never given a tool result, and one answered in the
    /// terminal that spawned it may not be either. Remembering what was settled
    /// keeps a resolved card from reappearing on the next refresh.
    private func resolve(_ question: QuestionRequest) {
        resolvedQuestionIDs.insert(question.id)
        pendingQuestions.removeAll { $0.id == question.id }
        transcriptQuestions.removeAll { $0.id == question.id }
        emit()
    }

    /// Questions the user still has to decide: whatever the backend pushed or
    /// the transcript implies, minus everything already answered or dismissed.
    private var openQuestions: [QuestionRequest] {
        var seen = Set<String>()
        return (pendingQuestions + transcriptQuestions).filter {
            !resolvedQuestionIDs.contains($0.id) && seen.insert($0.id).inserted
        }
    }

    /// Re-reads the transcript for an ask-the-user tool call still waiting on an
    /// answer. Cheap enough to run on every structural update, which is what
    /// makes a question asked mid-turn appear without its own event.
    private func syncTranscriptQuestions() {
        guard capabilitiesSupportQuestions else { return }
        transcriptQuestions = backend.pendingQuestions(
            in: reducer.snapshot, sessionID: sessionID)
    }

    private var capabilitiesSupportQuestions: Bool { backend.capabilities.supportsQuestions }

    /// Re-reads the transcript from the server and reports what went wrong if it could not. Takes
    /// the same buffered path every other refetch does, so a refresh asked for while an answer is
    /// streaming keeps the words that arrived during it.
    public func refresh() async throws {
        if let error = await refreshSerialized(generation: generation) { throw error }
    }

    /// A goal lookup must never fail a transcript refresh — a server too old to report goals just
    /// leaves the chip absent.
    private func fetchGoal() async -> SessionGoal? {
        guard backend.capabilities.supportsGoals else { return nil }
        return try? await backend.goal(for: sessionID)
    }

    /// Whether this server is holding a turn its machine cut off. Asked on every refetch, which is
    /// also the first thing a client does on opening a conversation — the interruption is noticed
    /// by the server while it is starting back up, so nobody is watching when it happens.
    ///
    /// A server that cannot answer throws, and throwing must not clear a card that is already up:
    /// only an answer of "nothing was interrupted" does that.
    private func fetchInterruption() async -> InterruptionReading {
        do {
            return .answered(try await backend.interruption(for: sessionID))
        } catch {
            return .cannotSay
        }
    }

    /// Picks the interrupted turn back up. The card comes down on the server's word, not on the
    /// press: a resume that the server refused leaves the offer exactly where it was.
    ///
    /// A server with no route for it still has the words: the prompt is in the transcript, so the
    /// turn is asked again rather than refused. That is the whole of what "picking it up" can mean
    /// on a machine that kept no memory of the work — and it is what a person would otherwise do
    /// by hand, from the same evidence, with more steps.
    public func resumeInterruptedTurn() async throws {
        let cutOff = interruption
        do {
            try await backend.resumeInterruption(sessionID: sessionID)
        } catch AgentError.unsupported {
            guard let prompt = cutOff?.prompt, !prompt.isEmpty else { throw AgentError.unsupported("interruption") }
            try await send(prompt)
        }
        interruption = nil
        emit()
    }

    /// Lets the interrupted turn go. The record goes; nothing in the transcript changes.
    ///
    /// A server that never held the record has nothing to forget, and a card this client put up
    /// on its own is this client's to take down — so its refusal is not an error to show anyone.
    public func dismissInterruptedTurn() async throws {
        do {
            try await backend.dismissInterruption(sessionID: sessionID)
        } catch AgentError.unsupported {
        }
        interruption = nil
        emit()
    }

    private func fetchQuestions() async -> [QuestionRequest] {
        (try? await backend.pendingQuestions(for: sessionID)) ?? []
    }

    /// The history fetch and the event-stream connection race concurrently to overlap their
    /// latencies, so events start arriving before there is a transcript to fold them into. They are
    /// buffered rather than applied and reconciled against the snapshot once it lands — the same
    /// path every later refetch takes, because every refetch has the same race inside it. Live
    /// events with no fetch out apply directly.
    private func runLoop(generation gen: Int) async {
        defer { clearStreamTask(generation: gen) }
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.staleTurnCheckInterval)
                await self?.nudgeIfStale(generation: gen)
            }
        }
        defer { watchdog.cancel() }
        recoveryRefreshInFlight = false
        droppedDeltaDuringRecovery = false
        reachedTerminal = false
        lastEventAt = Date()
        await seedFromCache(generation: gen)
        refreshInFlight = true
        bufferedEvents = []
        let initialRefresh = Task { [weak self] in
            await self?.refreshQuietly(generation: gen)
        }
        defer { initialRefresh.cancel() }

        var attempt = 0

        while gen == generation && !Task.isCancelled {
            setConnection(.connecting, generation: gen)
            do {
                for try await event in backend.events(for: sessionID) {
                    guard gen == generation else { return }
                    // Anything arriving off the transport proves the transport, whether or not
                    // there is a transcript to fold it into yet. Marking live only on the far
                    // side of the buffer meant a chat opened during its own first fetch stayed
                    // "connecting" until something was said in it.
                    attempt = 0
                    markLive(generation: gen)
                    if case .attached = event { continue }
                    if refreshInFlight {
                        bufferedEvents.append(event)
                        continue
                    }
                    apply(event, generation: gen)
                }
            } catch {
                guard gen == generation else { return }
                let failure = Self.failure(from: error)
                guard failure.retryable else {
                    lastFailure = failure
                    reachedTerminal = true
                    setConnection(.offline, generation: gen)
                    finish(generation: gen)
                    return
                }
                setFailure(failure, generation: gen)
            }

            await initialRefresh.value
            guard gen == generation && !Task.isCancelled else { return }

            attempt += 1
            if let maxAttempts = policy.maxReconnectAttempts, attempt > maxAttempts {
                setConnection(.offline, generation: gen)
                finish(generation: gen)
                return
            }

            setConnection(.reconnecting, generation: gen)
            await refreshQuietly(generation: gen)
            let delay = policy.backoffDelay(
                attempt: attempt - 1, jitterFraction: .random(in: 0...1))
            try? await Task.sleep(for: delay)
        }
    }

    /// Folds everything that streamed during a refetch onto the snapshot it just installed, and
    /// reopens the live path. Whether the fetch succeeded or failed, the events it held back are
    /// the only copy anyone has, so every ending drains — onto the new transcript when one landed,
    /// onto the old one when none did.
    ///
    /// A stream that failed for good is the exception, and takes its buffered events with it: the
    /// transcript it left is the last thing anyone can vouch for, and folding half a turn onto it
    /// would show a state the server never reported.
    private func drainBufferedEvents(generation gen: Int, alreadyFolded: [String: Int] = [:]) {
        let buffered = bufferedEvents
        refreshInFlight = false
        bufferedEvents = []
        guard !buffered.isEmpty, !reachedTerminal else { return }
        markLive(generation: gen)
        var credit = alreadyFolded
        for event in buffered {
            guard let owing = unfolded(event, against: &credit) else { continue }
            apply(owing, generation: gen)
        }
    }

    /// What is left of a held-back event once the refetch is credited with the part of it that
    /// already reached the transcript by another road.
    ///
    /// Only messages this device had never seen are ever credited, and for those the server's
    /// version and the buffer overlap without either containing the other: the answer began before
    /// the stream was dialled, so its head exists only in the snapshot, and it went on after the
    /// server built its reply, so its tail exists only here. Text is a length, so the overlap is a
    /// length too — the buffer pays the credit off character by character and starts landing where
    /// the server's account stops. A message upsert stops replacing parts while a credit stands,
    /// since the shell the stream repeats mid-turn carries none and would empty the answer.
    private func unfolded(_ event: BackendEvent, against credit: inout [String: Int])
        -> BackendEvent?
    {
        switch event {
        case .messageUpserted(let message, true) where (credit[message.id] ?? 0) > 0:
            return .messageUpserted(message, replaceParts: false)
        case .partTextDelta(let messageID, let partID, let delta):
            guard let owed = credit[messageID], owed > 0 else { return event }
            let length = delta.count
            credit[messageID] = max(0, owed - length)
            guard length > owed else { return nil }
            return .partTextDelta(
                messageID: messageID, partID: partID, delta: String(delta.dropFirst(owed)))
        default:
            return event
        }
    }

    /// Gives the messages the buffer is still writing back to the stream, over the versions of them
    /// the refetch just installed.
    ///
    /// A message an answer is being typed into is a moving target, and the server's snapshot of one
    /// is only a claim about where it had got to when it answered — claude-bridge folds every delta
    /// it broadcasts into the partial message it serves, so its snapshot already carries text this
    /// buffer is about to replay, and a backend that stores parts as they stream is no different.
    /// Replaying the buffer on top of the server's version therefore writes the same sentence
    /// twice, and dropping the buffer instead loses whatever only the stream saw. Restoring what
    /// this device held when the fetch went out — and only for the messages the buffer actually
    /// addresses — makes the result exactly what we had plus everything that arrived, once,
    /// without anyone having to know what a delta means to the backend that sent it.
    ///
    /// A message the buffer addresses that this device never held has no version to protect, and it
    /// is the one case where the buffer cannot simply be believed: opening a chat on a turn already
    /// in flight dials the stream first and asks for the transcript second, so the deltas that
    /// arrive in between are both held here and folded into the answer the server gives — and
    /// replaying them writes that stretch twice. Where the server turned out to hold the message,
    /// its version is the whole of it and the held text is named as already folded; where it did
    /// not, nothing but the buffer has ever seen the message and every event lands.
    private func restoreMessagesTheStreamIsWriting(from preRefresh: [ChatMessage]) -> [String: Int] {
        let addressed = bufferedMessageIDs()
        guard !addressed.isEmpty else { return [:] }
        let held = Set(preRefresh.map(\.id))
        for message in preRefresh where addressed.contains(message.id) {
            reducer.apply(.messageUpserted(message, replaceParts: true))
        }
        var credit: [String: Int] = [:]
        for message in reducer.snapshot
        where addressed.contains(message.id) && !held.contains(message.id) {
            let overlap = Self.overlap(
                of: bufferedText(for: message.id), alreadyIn: Self.text(of: message))
            if overlap > 0 { credit[message.id] = overlap }
        }
        return credit
    }

    /// How much of what the buffer is holding for a message the refetch already accounts for.
    ///
    /// Both sides are a prefix of the same answer, and neither contains the other: the server's
    /// copy starts at the beginning of the turn, which happened before the stream was dialled, and
    /// the buffer runs on past the moment the server composed its reply. What they share is where
    /// they meet — the longest opening of the buffer that the server's text already ends with — and
    /// that is a thing to be found rather than counted, since nothing here knows how much of the
    /// server's account predates the buffer entirely.
    private static func overlap(of buffered: String, alreadyIn served: String) -> Int {
        let limit = min(buffered.count, served.count)
        guard limit > 0 else { return 0 }
        for length in stride(from: limit, through: 1, by: -1)
        where served.hasSuffix(buffered.prefix(length)) {
            return length
        }
        return 0
    }

    private static func text(of message: ChatMessage) -> String {
        message.parts.reduce(into: "") { joined, part in
            if case .text(let text) = part.kind { joined += text }
        }
    }

    private func bufferedText(for messageID: String) -> String {
        bufferedEvents.reduce(into: "") { joined, event in
            if case .partTextDelta(let id, _, let delta) = event, id == messageID {
                joined += delta
            }
        }
    }

    /// The messages the held-back events name. Everything else in the snapshot is the server's to
    /// state, and a refetch exists to be believed about it.
    private func bufferedMessageIDs() -> Set<String> {
        var ids: Set<String> = []
        for event in bufferedEvents {
            switch event {
            case .messageUpserted(let message, _):
                ids.insert(message.id)
            case .partUpserted(let messageID, _), .partTextDelta(let messageID, _, _),
                .partRemoved(let messageID, _), .messageRemoved(let messageID):
                ids.insert(messageID)
            default:
                break
            }
        }
        return ids
    }

    private func markLive(generation gen: Int) {
        guard connection != .live else { return }
        lastFailure = nil
        setConnection(.live, generation: gen)
    }

    /// The server answered a request, which is proof it is reachable even though it may not have
    /// said anything on the socket yet.
    ///
    /// Only ever an upgrade out of ``ConnectionPhase/connecting``: a stream that has dropped is
    /// genuinely reconnecting and must keep saying so, and nothing here may talk a terminal
    /// failure back into looking healthy. What it fixes is the opening moment — a transcript that
    /// loaded, priced and drew its branch off a server that is plainly answering, under a label
    /// still claiming to be dialling it.
    private func markAnswered(generation gen: Int) {
        guard connection == .connecting else { return }
        setConnection(.live, generation: gen)
    }

    /// Builds a failure from a stream/refresh error, classifying its retryability so the reconnect
    /// loop can stop hammering a permanently-failing endpoint. Non-``AgentError`` errors default to
    /// retryable, preserving backoff for unrecognised transport faults.
    /// The banner never shows a raw error dump. A transport error's `describing` is a paragraph
    /// of `Error Domain=NSURLErrorDomain …` — that goes in `detail` for the log; the message a
    /// person sees names the situation in one clause.
    private static func failure(from error: Error) -> BackendFailure {
        let retryable = (error as? AgentError)?.isRetryable ?? true
        var message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        if let urlError = error as? URLError {
            message = urlError.localizedDescription
        }
        if message.count > 120 || message.contains("Error Domain") || message.contains("Code=") {
            message = AgentText.string("The server can't be reached right now.")
        }
        return BackendFailure(
            message: message, retryable: retryable, detail: String(describing: error))
    }

    /// A turn that claims to be running while its events have stopped arriving is either a slow
    /// model or a stream that died without saying so — a socket kept alive by heartbeats delivers
    /// nothing for this session and trips no other watchdog, and the reader is left watching half
    /// an answer forever. The transcript on the server is whole either way, so a quiet refetch is
    /// the one move that is free when the turn is merely slow and healing when it is not.
    private func nudgeIfStale(generation gen: Int) async {
        guard gen == generation, status == .running, connection == .live,
            !refreshInFlight, !recoveryRefreshInFlight,
            Date().timeIntervalSince(lastEventAt) > Self.staleTurnThreshold
        else { return }
        let before = CutOffTurn.fingerprint(reducer.snapshot)
        lastEventAt = Date()
        await refreshQuietly(generation: gen)
        noticeCutOffTurn(matching: before, generation: gen)
    }

    /// A turn that did not move by a character across a whole quiet stretch, on a server that
    /// cannot report its own interruptions, is a turn whose machine went — and the nudge that just
    /// re-read it has already paid for the evidence, so noticing costs nothing extra.
    ///
    /// A server that reports its own is left alone: it knows what this can only infer, and two
    /// answers to one question is how a card ends up contradicting itself.
    private func noticeCutOffTurn(matching before: CutOffTurn.Fingerprint?, generation gen: Int) {
        guard gen == generation, !backend.capabilities.reportsInterruptions, interruption == nil,
            status == .running, connection == .live, !refreshInFlight, let before,
            CutOffTurn.fingerprint(reducer.snapshot) == before,
            let cutOff = CutOffTurn.read(reducer.snapshot, detectedAt: Date())
        else { return }
        interruption = cutOff
        status = .idle
        emit()
    }

    private func apply(_ event: BackendEvent, generation gen: Int) {
        guard gen == generation else { return }
        lastEventAt = Date()
        switch event {
        case .partTextDelta(let messageID, let partID, _):
            if reducer.canAddress(messageID: messageID, partID: partID) {
                reducer.apply(event)
            } else {
                scheduleRecoveryRefresh(generation: gen)
            }
            if status != .running, impliesRunning(event) { status = .running }
        case .messageUpserted, .partUpserted, .partRemoved, .messageRemoved:
            reducer.apply(event)
            syncTranscriptQuestions()
            if status != .running, impliesRunning(event) { status = .running }
            persistDuringStream()
        case .status(let value):
            status = value
            if value == .idle || value == .stable { persist() }
        case .goal(let value):
            goal = value
        case .compaction(let value):
            let wasRunning = compaction?.isRunning == true
            compaction = value
            /// A compaction that just ended rewrote the transcript on the server: the summary
            /// message the stream delivered is not the seam the transcript wants, so re-read the
            /// authoritative messages once the dust settles rather than leaving the raw summary
            /// where the seam belongs.
            if wasRunning, value == nil { scheduleRecoveryRefresh(generation: gen) }
        case .interruption(let value):
            interruption = value
        case .attached:
            markLive(generation: gen)
        case .permission(let request):
            guard !resolvedPermissionIDs.contains(request.id) else { break }
            if !pendingPermissions.contains(where: { $0.id == request.id }) {
                pendingPermissions.append(request)
            }
        case .permissionResolved(let requestID):
            resolvedPermissionIDs.insert(requestID)
            pendingPermissions.removeAll { $0.id == requestID }
        case .question(let request):
            if !pendingQuestions.contains(where: { $0.id == request.id }) {
                pendingQuestions.append(request)
            }
        case .questionResolved(let requestID):
            resolvedQuestionIDs.insert(requestID)
            pendingQuestions.removeAll { $0.id == requestID }
            transcriptQuestions.removeAll { $0.id == requestID }
        case .failure(let failure):
            lastFailure = failure
            if status == .running { status = .idle }
        case .unknown:
            break
        }
        emit()
    }

    /// Live streaming activity on an unfinished assistant message means a turn
    /// is in flight — some backends (opencode) never send an explicit running
    /// status, so it has to be inferred or clients never see a busy state.
    /// Backends that never stamp `completedAt` (claude-bridge) get no upsert
    /// inference at all: there a nil `completedAt` is meaningless, and a late
    /// message upsert landing after the terminal idle would re-arm a running
    /// state that nothing could ever clear again. Text deltas still count —
    /// they only flow while tokens actually stream.
    private func impliesRunning(_ event: BackendEvent) -> Bool {
        switch event {
        case .partTextDelta:
            return reducer.snapshot.last?.role == .assistant
        case .messageUpserted(let message, _):
            guard backend.capabilities.reportsMessageCompletion else { return false }
            return message.role == .assistant && message.completedAt == nil
        case .partUpserted(let messageID, _):
            guard backend.capabilities.reportsMessageCompletion else { return false }
            guard let message = reducer.snapshot.last(where: { $0.id == messageID }) else {
                return false
            }
            return message.role == .assistant && message.completedAt == nil
        default:
            return false
        }
    }

    /// A delta the transcript cannot place means it diverged from the server's (e.g. a reconnect
    /// gap): a delta that names a part we don't have, and equally a delta that names only a message
    /// we don't have, since the block it belongs to is a question only that message can answer.
    /// Applying either would fabricate a bubble that starts mid-response, so drop it and re-fetch
    /// instead. A drop that lands while a recovery fetch is already in flight is recorded so the
    /// fetch reruns and converges rather than silently losing the delta.
    private func scheduleRecoveryRefresh(generation gen: Int) {
        guard !recoveryRefreshInFlight else {
            droppedDeltaDuringRecovery = true
            return
        }
        recoveryRefreshInFlight = true
        Task { [weak self] in
            await self?.recoveryRefresh(generation: gen)
        }
    }

    /// Re-fetches the transcript, then repeats while deltas kept dropping during the fetch — each
    /// pass narrows the gap to a single roundtrip so a burst of deltas for a still-missing part
    /// can't leave a permanent hole. Bounded so a continuously-streaming turn can't refetch forever;
    /// any residual gap heals at the next full part/message upsert.
    private func recoveryRefresh(generation gen: Int) async {
        var passes = 0
        repeat {
            droppedDeltaDuringRecovery = false
            await refreshQuietly(generation: gen)
            guard gen == generation else { break }
            passes += 1
        } while droppedDeltaDuringRecovery && passes < Self.maxRecoveryRefreshPasses
        recoveryRefreshInFlight = false
    }

    /// The transcript is the source of truth after a refresh: status events
    /// that fired while we were disconnected are gone forever, so a completed
    /// or visibly-streaming last message must correct a stale status.
    private func deriveStatusFromTranscript() {
        guard let last = reducer.snapshot.last, last.role == .assistant else { return }
        if last.completedAt != nil {
            if status == .running { status = .idle }
        } else if last.isStreaming, interruption?.turnID != last.id {
            if status != .running { status = .running }
        }
    }

    private func seedFromCache(generation gen: Int) async {
        guard let cache, reducer.snapshot.isEmpty else { return }
        let cached = await cache.messages(for: sessionID)
        guard gen == generation, !cached.isEmpty, reducer.snapshot.isEmpty else { return }
        reducer = MessageReducer(agentType: backend.agentType, messages: cached)
        loadedTranscript = true
        syncTranscriptQuestions()
        emit()
    }

    /// A refetch nobody asked for, so a failure is a banner rather than a thrown error.
    private func refreshQuietly(generation gen: Int) async {
        guard let error = await refreshSerialized(generation: gen),
            !(error is CancellationError), gen == generation, !reachedTerminal
        else { return }
        lastFailure = Self.failure(from: error)
        emit()
    }

    /// Refetches run one at a time, in the order they were asked for.
    ///
    /// Two overlapping fetches each rebuild the transcript from their own snapshot, so the slower
    /// one silently undoes the newer one, and neither can say which of the buffered events the
    /// other already folded in. Queued, the buffer belongs to exactly one fetch at a time and every
    /// later fetch is strictly newer than everything replayed before it. The queue carries the
    /// caller's cancellation through to the request, so closing a chat still abandons its load.
    private func refreshSerialized(generation gen: Int) async -> Error? {
        let previous = refreshChain
        let task = Task { [weak self] () -> Error? in
            _ = await previous?.value
            return await self?.performRefresh(generation: gen) ?? nil
        }
        refreshChain = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Re-reads the transcript and folds back whatever streamed while the read was out.
    ///
    /// An actor is re-entrant across `await`: the run loop keeps delivering events through the
    /// fetch, and every one of them applied in that window would be thrown away by the rebuild that
    /// follows — the whole reason a turn watched during a refetch used to lose the middle of its
    /// answer. So the events are held instead and replayed on top of the snapshot; a fetch that
    /// failed installs nothing and replays them onto the transcript that was already there.
    ///
    /// The three fetches ride concurrently: on a bridge answering a heavy machine each round trip
    /// can cost real time, and paying them in sequence is what made a freshly opened chat sit on
    /// its placeholder.
    ///
    /// A message the stream is actively writing belongs to the stream, so the snapshot may not
    /// install its version of one — see ``restoreMessagesTheStreamIsWriting(from:)``.
    ///
    /// A generation that is no longer the current one leaves everything exactly as it found it —
    /// the buffer and the hold on live events belong to the run loop that replaced it, which is
    /// re-reading the transcript itself. The check is made again here, after the queue has been
    /// waited on, so a refetch a reconnect superseded while it sat in the chain never goes out.
    private func performRefresh(generation gen: Int) async -> Error? {
        guard gen == generation else { return nil }
        refreshInFlight = true
        let preRefresh = reducer.snapshot
        do {
            async let questionsFetch = fetchQuestions()
            async let goalFetch = fetchGoal()
            let messages = try await backend.messages(for: sessionID)
            let (questions, goal) = await (questionsFetch, goalFetch)
            let cutOff = await fetchInterruption()
            guard gen == generation else { return nil }
            guard !reachedTerminal else {
                drainBufferedEvents(generation: gen)
                return nil
            }
            reducer = MessageReducer(agentType: backend.agentType, messages: messages)
            let folded = restoreMessagesTheStreamIsWriting(from: preRefresh)
            loadedTranscript = true
            deriveStatusFromTranscript()
            if capabilitiesSupportQuestions { pendingQuestions = questions }
            syncTranscriptQuestions()
            if backend.capabilities.supportsGoals { self.goal = goal }
            if case .answered(let cut) = cutOff { interruption = cut }
            lastFailure = nil
            markAnswered(generation: gen)
            drainBufferedEvents(generation: gen, alreadyFolded: folded)
            persist()
            emit()
            return nil
        } catch {
            guard gen == generation else { return error }
            drainBufferedEvents(generation: gen)
            return error
        }
    }

    /// A turn can stream for an hour; a cache written only at idle restores an hour stale. Every
    /// few seconds of applied events reaches disk, so a relaunch mid-turn reopens on the newest
    /// content the app ever saw rather than on the last completed turn.
    private func persistDuringStream() {
        guard Date().timeIntervalSince(lastStreamPersist) > 5 else { return }
        persist()
    }

    /// Chains onto the previous persist so writes reach the cache in order;
    /// a cancelled predecessor may still complete, but never after this one.
    private func persist() {
        guard let cache else { return }
        lastStreamPersist = Date()
        let snapshot = reducer.snapshot
        let sessionID = sessionID
        persistTask = Task { [previous = persistTask] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await cache.store(snapshot, for: sessionID)
        }
    }

    private func setConnection(_ phase: ConnectionPhase, generation gen: Int) {
        guard gen == generation else { return }
        guard phase != connection else { return }
        connection = phase
        connectionChangedAt = Date()
        emit()
    }

    private func setFailure(_ failure: BackendFailure, generation gen: Int) {
        guard gen == generation else { return }
        lastFailure = failure
        emit()
    }

    private func emit() {
        let snapshot = state
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    private func finish(generation gen: Int) {
        guard gen == generation else { return }
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        persistTask?.cancel()
        persistTask = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }
}
