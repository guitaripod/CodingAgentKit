import AgentCore
import Foundation
import OpenCodeKit
import Synchronization

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct MockScriptStep: Sendable {
    public var event: BackendEvent
    public var delay: Duration

    public init(_ event: BackendEvent, delay: Duration = .milliseconds(20)) {
        self.event = event
        self.delay = delay
    }
}

/// A scriptable in-memory backend for previews, deterministic tests, and shippable demo modes.
///
/// `events(for:)` replays the session's script with per-step delays. When `failAfter` is set, the
/// FIRST subscription throws after that many events (simulating a mid-stream drop); later
/// subscriptions replay the full script — which is how the reconnect path is exercised.
///
/// With `interactive: true` the event stream stays open after the replay and `send` answers each
/// prompt with the next `replyTurns` script (cycled, retagged with unique message ids and fresh
/// dates), streamed live to that session's subscribers — enough to hold a real conversation
/// against scripted content.
public final class MockBackend: FileBrowsingBackend, GitObservingBackend, Sendable {
    public let agentType: AgentType
    public let capabilities: BackendCapabilities

    private let script: [MockScriptStep]
    /// How many of the script's steps the transcript the backend *serves* already reflects. Nil
    /// means all of them — the default, where a read and the stream agree. A prefix models a
    /// transcript that has not caught up with the stream: everything past it arrives over the
    /// stream only, which is how a seam that did not exist when the conversation was read is
    /// exercised.
    private let transcriptPrefix: Int?
    private let scripts: [String: [MockScriptStep]]
    private let replyTurns: [[MockScriptStep]]
    private let interactive: Bool
    private let failAfter: Int?
    private let failure: BackendFailure
    private let models: [ModelInfo]
    private let modelsFailures: Int
    private let defaultModelID: String?
    private let effortOptions: [String]
    private let serverHealth: ServerHealth
    private let quota: UsageQuota?
    private let analytics: UsageAnalyticsReport?
    private let additionalQuotas: [UsageQuota]
    private let usage: AgentUsage?
    private let fileTree: [String: [FileNode]]
    private let fileContents: [String: String]
    private let diffs: [FileDiff]
    private let subagentSummaries: [SubagentSummary]
    private let subagentOwners: [String: [SubagentSummary]]
    private let subagentScripts: [String: [MockScriptStep]]
    private let derivesQuestionsFromTranscript: Bool
    private let commands: [AgentCommand]
    private let git: GitSnapshot?
    private let gitPatches: [String: String]
    private let waitSupport: TurnWaitSupport
    private let waitResults: [String: [TurnWaitResult]]
    private let pushReceipt: DevicePushRegistration.Receipt
    private let mutable = Mutex(Mutable())

    private struct Mutable {
        var subscriptions = 0
        var sentPrompts: [SendPrompt] = []
        var backgroundStops: [String] = []
        var reverts: [String] = []
        var restores: [String] = []
        var standingReverts: [String: SessionRevert] = [:]
        var sessions: [AgentSession] = []
        var appendedEvents: [String: [MockScriptStep]] = [:]
        var cleared: Set<String> = []
        var continuations: [String: [UUID: AsyncThrowingStream<BackendEvent, Error>.Continuation]] = [:]
        var replyIndex = 0
        var mintCounter = 0
        var modelsFailures = 0
        var waitCallCounts: [String: Int] = [:]
        var transcriptOnly: [String: [ChatMessage]] = [:]
        var transcriptStatus: BackendStatus?
        var runningCompaction: CompactionActivity?
        var transcriptDelay: Duration = .zero
        var queues: [String: QueueSnapshot] = [:]
        var queuedPrompts: [String: EnqueuePrompt] = [:]
        var startedQueueIDs: Set<String> = []
        var enqueueRequests: [EnqueuePrompt] = []
        var queueEdits: [String] = []
        var queueCancels: [String] = []
        var queueResumes = 0
    }

    public init(
        agentType: AgentType = .openCode,
        script: [MockScriptStep] = [],
        scripts: [String: [MockScriptStep]] = [:],
        replyTurns: [[MockScriptStep]] = [],
        interactive: Bool = false,
        failAfter: Int? = nil,
        failure: BackendFailure = BackendFailure(message: "mock failure", retryable: true),
        sessions: [AgentSession]? = nil,
        models: [ModelInfo] = [],
        modelsFailures: Int = 0,
        defaultModelID: String? = nil,
        reasoningEffortOptions: [String] = [],
        health: ServerHealth = ServerHealth(healthy: true, version: "mock"),
        capabilities: BackendCapabilities? = nil,
        quota: UsageQuota? = nil,
        additionalQuotas: [UsageQuota] = [],
        sessionUsage: AgentUsage? = nil,
        analytics: UsageAnalyticsReport? = nil,
        fileTree: [String: [FileNode]] = [:],
        fileContents: [String: String] = [:],
        diffs: [FileDiff] = [],
        subagents: [SubagentSummary] = [],
        subagentsBySession: [String: [SubagentSummary]] = [:],
        subagentScripts: [String: [MockScriptStep]] = [:],
        derivesQuestionsFromTranscript: Bool = false,
        commands: [AgentCommand] = MockBackend.demoCommands,
        git: GitSnapshot? = nil,
        gitPatches: [String: String] = [:],
        transcriptPrefix: Int? = nil,
        turnWaitSupport: TurnWaitSupport = .supported,
        turnWaitResults: [String: [TurnWaitResult]] = [:],
        pushReceipt: DevicePushRegistration.Receipt = DevicePushRegistration.Receipt(),
        serverQueue: Bool = false
    ) {
        self.agentType = agentType
        self.script = script
        self.transcriptPrefix = transcriptPrefix
        self.scripts = scripts
        self.replyTurns = replyTurns
        self.interactive = interactive
        self.failAfter = failAfter
        self.failure = failure
        self.models = models
        self.modelsFailures = modelsFailures
        self.defaultModelID = defaultModelID
        self.effortOptions = reasoningEffortOptions
        self.serverHealth = health
        self.quota = quota
        self.additionalQuotas = additionalQuotas
        self.usage = sessionUsage
        self.analytics = analytics
        self.fileTree = fileTree
        self.fileContents = fileContents
        self.diffs = diffs
        self.subagentSummaries = subagents
        self.subagentOwners = subagentsBySession
        self.subagentScripts = subagentScripts
        self.derivesQuestionsFromTranscript = derivesQuestionsFromTranscript
        self.commands = commands
        self.git = git
        self.gitPatches = gitPatches
        self.waitSupport = turnWaitSupport
        self.waitResults = turnWaitResults
        self.pushReceipt = pushReceipt
        self.capabilities =
            capabilities
            ?? BackendCapabilities(
                supportsFileBrowsing: true, supportsDiffs: true, supportsPermissions: true,
                supportsMultipleSessions: true, supportsModelSelection: true,
                supportsAttachments: true, supportsAbort: true, supportsSessionUsage: true,
                supportsQuestions: true, supportsCommands: !commands.isEmpty,
                supportsCompaction: true, supportsCompactionInstructions: true,
                supportsServerQueue: serverQueue, supportsQueueEdit: serverQueue)
        mutable.withLock {
            $0.modelsFailures = modelsFailures
            $0.sessions =
                sessions
                ?? [
                    AgentSession(
                        id: "mock", agentType: agentType, title: "Mock session",
                        createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0))
                ]
        }
    }

    /// Puts a message in the transcript the backend serves that the stream never delivers — a seam
    /// the compaction wrote while the client was not listening.
    public func serveInTranscriptOnly(_ message: ChatMessage, for sessionID: String) {
        mutable.withLock { $0.transcriptOnly[sessionID, default: []].append(message) }
    }

    /// What the served transcript says about the turn, the way a server that reports whether one
    /// is open does. Nil, the default, is a server that does not say.
    public func serveTranscriptStatus(_ status: BackendStatus?) {
        mutable.withLock { $0.transcriptStatus = status }
    }

    /// How long a read of the transcript takes, so the stream can be heard before the conversation
    /// has been read at all.
    public func delayTranscript(by delay: Duration) {
        mutable.withLock { $0.transcriptDelay = delay }
    }

    /// What a read of the compaction in flight answers, the way a server that can tell does.
    public func serveRunningCompaction(_ activity: CompactionActivity?) {
        mutable.withLock { $0.runningCompaction = activity }
    }

    public func runningCompaction(for sessionID: String) async throws -> CompactionActivity? {
        mutable.withLock { $0.runningCompaction }
    }

    public var recordedPrompts: [SendPrompt] { mutable.withLock { $0.sentPrompts } }
    /// Every session whose background work a client asked to stop, in order.
    public var backgroundStops: [String] { mutable.withLock { $0.backgroundStops } }
    /// Every message a client asked to revert to, in order.
    public var reverts: [String] { mutable.withLock { $0.reverts } }
    /// Every session a client asked to bring a revert back on, in order.
    public var restores: [String] { mutable.withLock { $0.restores } }

    public func availableCommands(directory: String?) async throws -> [AgentCommand] { commands }

    /// A catalog shaped like a real machine's rather than a token one: the agent's own verbs, a
    /// command the project contributes, one from a plugin, an MCP prompt and a skill — the mix a
    /// completion list has to stay legible under, and the only commands a demo can show off.
    public static let demoCommands: [AgentCommand] = [
        AgentCommand(name: "compact", details: "Summarise the conversation and carry the summary forward", argumentHint: "<what the summary must keep>", source: .builtin),
        AgentCommand(name: "context", details: "How much of the window this conversation is using", source: .builtin),
        AgentCommand(name: "goal", details: "Keep working until a condition is met", argumentHint: "<condition> | clear", source: .builtin),
        AgentCommand(name: "init", details: "Write an AGENTS.md for this project", source: .builtin),
        AgentCommand(name: "review", details: "Review the working diff", argumentHint: "[path]", source: .builtin),
        AgentCommand(name: "usage", details: "Tokens and spend for this session", source: .builtin),
        AgentCommand(name: "test", details: "Run the suite and triage what fails", source: .project, scope: "pulse-server"),
        AgentCommand(name: "deploy", details: "Ship the current branch to staging", argumentHint: "<environment>", source: .project, scope: "pulse-server"),
        AgentCommand(name: "pr:open", details: "Open a pull request from this branch", argumentHint: "<title>", source: .plugin, scope: "github"),
        AgentCommand(name: "pr:review", details: "Review an open pull request", argumentHint: "<number>", source: .plugin, scope: "github"),
        AgentCommand(name: "linear:issue", details: "Create an issue from this conversation", argumentHint: "<title>", source: .mcp, scope: "linear"),
        AgentCommand(name: "security-review", details: "Audit the pending changes for vulnerabilities", source: .skill),
        AgentCommand(name: "simplify", details: "Reuse, simplify and tidy the changed code", source: .skill),
    ]

    public func health() async throws -> ServerHealth { serverHealth }
    public func listSessions() async throws -> [AgentSession] { mutable.withLock { $0.sessions } }

    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        mutable.withLock { state in
            state.mintCounter += 1
            let session = AgentSession(
                id: "mock-new-\(state.mintCounter)", agentType: agentType,
                title: title ?? "New chat", directory: directory,
                createdAt: Date(), updatedAt: Date())
            state.sessions.insert(session, at: 0)
            return session
        }
    }

    public func deleteSession(_ sessionID: String) async throws {
        mutable.withLock { $0.sessions.removeAll { $0.id == sessionID } }
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        mutable.withLock { state in
            guard let index = state.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            state.sessions[index].title = title
            state.sessions[index].updatedAt = Date()
        }
    }

    public func forkSession(_ sessionID: String) async throws -> AgentSession {
        mutable.withLock { state in
            state.mintCounter += 1
            let original = state.sessions.first { $0.id == sessionID }
            let fork = AgentSession(
                id: "mock-fork-\(state.mintCounter)", agentType: agentType,
                title: "Fork: \(original?.title ?? sessionID)", directory: original?.directory,
                createdAt: Date(), updatedAt: Date())
            state.sessions.insert(fork, at: 0)
            state.appendedEvents[fork.id] = state.appendedEvents[sessionID] ?? []
            if scripts[fork.id] == nil, let base = scripts[sessionID] {
                state.appendedEvents[fork.id] = base + (state.appendedEvents[fork.id] ?? [])
            }
            return fork
        }
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        var reducer = MessageReducer(agentType: agentType)
        let log = fullLog(for: sessionID)
        let served = transcriptPrefix.map { Array(log.prefix($0)) } ?? log
        for step in served { reducer.apply(step.event) }
        for message in mutable.withLock({ $0.transcriptOnly[sessionID] ?? [] }) {
            reducer.apply(.messageUpserted(message, replaceParts: true))
        }
        return reducer.snapshot
    }

    /// The messages with the revert standing on the session, the way a server that keeps one on
    /// its record answers a re-read.
    public func transcript(for sessionID: String) async throws -> TranscriptSnapshot {
        let delay = mutable.withLock { $0.transcriptDelay }
        if delay > .zero { try await Task.sleep(for: delay) }
        let messages = try await messages(for: sessionID)
        return TranscriptSnapshot(
            messages: messages, status: mutable.withLock { $0.transcriptStatus },
            revert: mutable.withLock { $0.standingReverts[sessionID] },
            queue: capabilities.supportsServerQueue
                ? mutable.withLock { $0.queues[sessionID] ?? .empty } : nil)
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        let turn: [MockScriptStep]? = mutable.withLock { state in
            state.sentPrompts.append(prompt)
            guard interactive else { return nil }
            var steps = commitStandingRevert(on: sessionID, in: &state)
            state.mintCounter += 1
            let suffix = "#\(state.mintCounter)"
            var parts = [MessagePart(id: "t", kind: .text(prompt.text))]
            for (index, attachment) in prompt.attachments.enumerated() {
                parts.append(
                    MessagePart(
                        id: "f\(index)",
                        kind: .file(
                            FileReference(
                                mime: attachment.mime, filename: attachment.filename ?? "attachment"))))
            }
            steps.append(
                MockScriptStep(
                    .messageUpserted(
                        ChatMessage(
                            id: "user\(suffix)", role: .user, agentType: agentType,
                            parts: parts, createdAt: Date()),
                        replaceParts: true), delay: .milliseconds(80)))
            steps.append(MockScriptStep(.status(.running), delay: .milliseconds(200)))
            if !replyTurns.isEmpty {
                let reply = replyTurns[state.replyIndex % replyTurns.count]
                state.replyIndex += 1
                steps += Self.retagged(reply, suffix: suffix)
            }
            steps.append(MockScriptStep(.status(.idle), delay: .milliseconds(150)))
            if let index = state.sessions.firstIndex(where: { $0.id == sessionID }) {
                state.sessions[index].updatedAt = Date()
            }
            return steps
        }
        guard let turn else { return }
        stream(turn, to: sessionID)
    }

    public func abort(sessionID: String) async throws {
        pauseQueueAfterStop(sessionID)
        guard interactive else { return }
        stream([MockScriptStep(.status(.idle), delay: .zero)], to: sessionID)
    }

    /// Winds the session back to `messageID`, putting back the files the demo's diffs name so a
    /// revert in the demo world says what it undid, and tells the session's stream. The revert
    /// stands on the session until it is restored or the next message makes it final.
    public func revert(sessionID: String, to messageID: String) async throws -> SessionRevert {
        let revert = SessionRevert(
            messageID: messageID,
            files: diffs.map {
                SessionRevert.File(
                    path: $0.path, change: .modified, additions: $0.additions,
                    deletions: $0.deletions)
            })
        mutable.withLock { state in
            state.reverts.append(messageID)
            state.standingReverts[sessionID] = revert
        }
        if interactive { stream([MockScriptStep(.revert(revert), delay: .zero)], to: sessionID) }
        return revert
    }

    public func restoreRevert(sessionID: String) async throws {
        mutable.withLock { state in
            state.restores.append(sessionID)
            state.standingReverts[sessionID] = nil
        }
        guard interactive else { return }
        stream([MockScriptStep(.revert(nil), delay: .zero)], to: sessionID)
    }

    /// Every prompt a client handed to the queue, in order, repeats included.
    public var recordedEnqueues: [EnqueuePrompt] { mutable.withLock { $0.enqueueRequests } }
    /// The ids of every queued prompt a client edited, in order.
    public var recordedQueueEdits: [String] { mutable.withLock { $0.queueEdits } }
    /// The ids of every queued prompt a client cancelled, in order.
    public var recordedQueueCancels: [String] { mutable.withLock { $0.queueCancels } }
    /// How many times a client lifted the pause.
    public var recordedQueueResumes: Int { mutable.withLock { $0.queueResumes } }

    /// What the server's queue holds for the session, the way a server that keeps one answers a
    /// read. It is not announced: use ``announceQueue(for:)`` to tell the session's stream.
    public func serveQueue(_ snapshot: QueueSnapshot, for sessionID: String) {
        mutable.withLock { $0.queues[sessionID] = snapshot }
    }

    /// The queue as the server holds it now.
    public func servedQueue(for sessionID: String) -> QueueSnapshot {
        mutable.withLock { $0.queues[sessionID] ?? .empty }
    }

    /// Tells the session's live stream the queue as it stands. Announcements are never added to
    /// the replayed log, so a reconnect does not replay a queue that is no longer the queue.
    public func announceQueue(for sessionID: String) {
        broadcast(.queue(servedQueue(for: sessionID)), to: sessionID)
    }

    /// Starts a waiting prompt the way the server does when its turn comes: it leaves the queue,
    /// a later cancel or edit of it is refused, and the queue is announced. In an interactive mock
    /// it also runs the turn.
    public func startQueued(id: String, in sessionID: String) async {
        let started = mutable.withLock { state in
            takeQueued(id: id, in: sessionID, state: &state)
        }
        announceQueue(for: sessionID)
        if let started { try? await send(started.prompt, to: sessionID) }
    }

    /// Enqueues like a server that keeps the queue: a repeat of an id changes nothing, a prompt
    /// with nothing running starts at once and never appears in the queue, and the session is
    /// busy exactly when ``serveTranscriptStatus(_:)`` says a turn is open. Enqueueing clears
    /// the pause, and on an idle session with a queue the head starts.
    public func enqueue(sessionID: String, prompt: EnqueuePrompt) async throws -> EnqueueResult {
        guard capabilities.supportsServerQueue else { throw AgentError.unsupported("queue") }
        let (result, starting, changed) = mutable.withLock { state in
            state.enqueueRequests.append(prompt)
            var queue = state.queues[sessionID] ?? .empty
            if queue.items.contains(where: { $0.id == prompt.id }) {
                return (EnqueueResult(started: false, queue: queue), [EnqueuePrompt](), false)
            }
            if state.startedQueueIDs.contains(prompt.id) {
                return (EnqueueResult(started: true, queue: queue), [], false)
            }
            let idle = state.transcriptStatus != .running
            if idle, queue.items.isEmpty {
                state.startedQueueIDs.insert(prompt.id)
                queue.paused = false
                state.queues[sessionID] = queue
                return (EnqueueResult(started: true, queue: queue), [prompt], true)
            }
            queue.paused = false
            queue.items.append(Self.queued(prompt))
            state.queuedPrompts[prompt.id] = prompt
            state.queues[sessionID] = queue
            var starting: [EnqueuePrompt] = []
            if idle, let head = queue.items.first {
                if let started = takeQueued(id: head.id, in: sessionID, state: &state) {
                    starting.append(started)
                }
            }
            return (
                EnqueueResult(started: false, queue: state.queues[sessionID] ?? .empty), starting,
                true
            )
        }
        if changed { announceQueue(for: sessionID) }
        for started in starting { try? await send(started.prompt, to: sessionID) }
        return result
    }

    public func editQueued(sessionID: String, id: String, edit: QueuedPromptEdit) async throws
        -> QueueSnapshot
    {
        guard capabilities.supportsQueueEdit else { throw AgentError.unsupported("queue") }
        let snapshot = try mutable.withLock { state -> QueueSnapshot in
            state.queueEdits.append(id)
            var queue = state.queues[sessionID] ?? .empty
            guard let index = queue.items.firstIndex(where: { $0.id == id }) else {
                throw QueueError.alreadyStarted
            }
            if let text = edit.text { queue.items[index].text = text }
            if let model = edit.model { queue.items[index].model = model.modelID }
            if let effort = edit.reasoningEffort { queue.items[index].effort = effort }
            state.queues[sessionID] = queue
            return queue
        }
        announceQueue(for: sessionID)
        return snapshot
    }

    public func cancelQueued(sessionID: String, id: String) async throws -> QueueSnapshot {
        guard capabilities.supportsServerQueue else { throw AgentError.unsupported("queue") }
        let (snapshot, removed) = try mutable.withLock { state -> (QueueSnapshot, Bool) in
            state.queueCancels.append(id)
            var queue = state.queues[sessionID] ?? .empty
            guard let index = queue.items.firstIndex(where: { $0.id == id }) else {
                if state.startedQueueIDs.contains(id) { throw QueueError.alreadyStarted }
                return (queue, false)
            }
            queue.items.remove(at: index)
            state.queuedPrompts[id] = nil
            state.queues[sessionID] = queue
            return (queue, true)
        }
        if removed { announceQueue(for: sessionID) }
        return snapshot
    }

    public func resumeQueue(sessionID: String) async throws -> QueueSnapshot {
        guard capabilities.supportsServerQueue else { throw AgentError.unsupported("queue") }
        let (snapshot, starting) = mutable.withLock { state -> (QueueSnapshot, [EnqueuePrompt]) in
            state.queueResumes += 1
            var queue = state.queues[sessionID] ?? .empty
            queue.paused = false
            state.queues[sessionID] = queue
            var starting: [EnqueuePrompt] = []
            if state.transcriptStatus != .running, let head = queue.items.first,
                let started = takeQueued(id: head.id, in: sessionID, state: &state)
            {
                starting.append(started)
            }
            return (state.queues[sessionID] ?? .empty, starting)
        }
        announceQueue(for: sessionID)
        for started in starting { try? await send(started.prompt, to: sessionID) }
        return snapshot
    }

    private func takeQueued(id: String, in sessionID: String, state: inout Mutable) -> EnqueuePrompt?
    {
        var queue = state.queues[sessionID] ?? .empty
        guard let index = queue.items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = queue.items.remove(at: index)
        state.queues[sessionID] = queue
        state.startedQueueIDs.insert(id)
        return state.queuedPrompts.removeValue(forKey: id) ?? Self.prompt(of: item)
    }

    /// The prompt a queue item stands for, for an item the server was handed in its served
    /// queue rather than through an enqueue.
    private static func prompt(of item: QueuedPrompt) -> EnqueuePrompt {
        EnqueuePrompt(
            id: item.id, kind: item.kind,
            prompt: SendPrompt(
                text: item.text,
                model: item.model.map { ModelSelection(providerID: "mock", modelID: $0) },
                reasoningEffort: item.effort))
    }

    /// A Stop ends the running turn and holds the queue back, the way the server does.
    private func pauseQueueAfterStop(_ sessionID: String) {
        let paused = mutable.withLock { state -> Bool in
            guard capabilities.supportsServerQueue, var queue = state.queues[sessionID],
                !queue.items.isEmpty
            else { return false }
            queue.paused = true
            state.queues[sessionID] = queue
            return true
        }
        if paused { announceQueue(for: sessionID) }
    }

    private static func queued(_ prompt: EnqueuePrompt) -> QueuedPrompt {
        QueuedPrompt(
            id: prompt.id, text: prompt.prompt.text, kind: prompt.kind,
            model: prompt.prompt.model?.modelID, effort: prompt.prompt.reasoningEffort,
            attachments: prompt.prompt.attachments.map {
                QueuedAttachment(mime: $0.mime, filename: $0.filename, size: $0.data?.count)
            },
            createdAt: Date())
    }

    /// Yields an event to the session's live subscribers without adding it to the replayed log.
    private func broadcast(_ event: BackendEvent, to sessionID: String) {
        let targets = mutable.withLock { Array(($0.continuations[sessionID] ?? [:]).values) }
        for continuation in targets { continuation.yield(event) }
    }

    public func registerDeviceTokenReceipt(
        _ registration: DevicePushRegistration
    ) async throws -> DevicePushRegistration.Receipt {
        pushReceipt
    }

    public func turnWaitSupport() async -> TurnWaitSupport { waitSupport }

    /// A placeholder request scripted tests never actually send — the session id rides the URL
    /// only so a test can tell one session's request from another's at a glance.
    public func turnWaitRequest(for sessionID: String) async throws -> TurnWaitRequest? {
        guard waitSupport == .supported else { return nil }
        var request = URLRequest(url: URL(string: "https://mock.invalid/wait/\(sessionID)")!)
        request.httpMethod = "GET"
        return TurnWaitRequest(request: request, uploadsEmptyBody: false)
    }

    /// Ignores the status and body a real backend would decode off the wire — a mock never puts
    /// one there — and instead answers the next result scripted for this session, advancing its
    /// own call count so a script of several answers plays out in order and the last one repeats
    /// for every call past the end of the script.
    public func turnWaitResult(
        status: Int, headers: [String: String], body: Data, sessionID: String
    ) async throws -> TurnWaitResult {
        guard let queued = waitResults[sessionID], !queued.isEmpty else {
            throw AgentError.unsupported("turn wait")
        }
        let index = mutable.withLock { state -> Int in
            let current = state.waitCallCounts[sessionID, default: 0]
            state.waitCallCounts[sessionID] = current + 1
            return current
        }
        return queued[min(index, queued.count - 1)]
    }

    /// Makes the session's standing revert final the way a server does when the next message
    /// arrives: the commit is announced, and the messages it set aside leave the log for good, so
    /// a later re-read agrees with what the stream said.
    private func commitStandingRevert(on sessionID: String, in state: inout Mutable)
        -> [MockScriptStep]
    {
        guard let standing = state.standingReverts.removeValue(forKey: sessionID) else { return [] }
        var reducer = MessageReducer(agentType: agentType)
        let base = state.cleared.contains(sessionID) ? [] : baseScript(for: sessionID)
        for step in base + (state.appendedEvents[sessionID] ?? []) { reducer.apply(step.event) }
        let transcript = reducer.snapshot
        let setAside =
            transcript.firstIndex { $0.id == standing.messageID }.map { transcript[$0...] } ?? []
        return [MockScriptStep(.revertCommitted(messageID: standing.messageID), delay: .zero)]
            + setAside.map { MockScriptStep(.messageRemoved(messageID: $0.id), delay: .zero) }
    }

    /// Ends the mock's background work: the session is told the work is gone, and the request is
    /// remembered so a test can see that the client asked.
    public func stopBackgroundWork(sessionID: String) async throws {
        mutable.withLock { $0.backgroundStops.append(sessionID) }
        guard interactive else { return }
        stream([MockScriptStep(.backgroundWork(nil), delay: .zero)], to: sessionID)
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {}

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        guard interactive else { return }
        stream(
            [MockScriptStep(.questionResolved(requestID: request.id), delay: .zero)],
            to: request.sessionID)
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        guard interactive else { return }
        stream(
            [MockScriptStep(.questionResolved(requestID: request.id), delay: .zero)],
            to: request.sessionID)
    }

    public func clearConversation(_ sessionID: String) async throws {
        mutable.withLock { state in
            state.cleared.insert(sessionID)
            state.appendedEvents[sessionID] = []
        }
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let failAt = mutable.withLock { state -> Int? in
            state.subscriptions += 1
            return state.subscriptions == 1 ? failAfter : nil
        }
        let (replay, snapshotAppendedCount) = replaySnapshot(for: sessionID)
        let failure = failure
        let interactive = interactive
        return AsyncThrowingStream { continuation in
            let token = UUID()
            let task = Task { [weak self] in
                var count = 0
                for step in replay {
                    if Task.isCancelled { return }
                    if let failAt, count == failAt {
                        continuation.finish(throwing: failure)
                        return
                    }
                    try? await Task.sleep(for: step.delay)
                    continuation.yield(step.event)
                    count += 1
                }
                if let failAt, count == failAt {
                    continuation.finish(throwing: failure)
                    return
                }
                guard interactive, let self else {
                    continuation.finish()
                    return
                }
                self.registerLiveContinuation(
                    continuation, token: token, sessionID: sessionID,
                    deliveringAppendedAfter: snapshotAppendedCount)
            }
            continuation.onTermination = { [weak self] _ in
                task.cancel()
                self?.mutable.withLock { _ = $0.continuations[sessionID]?.removeValue(forKey: token) }
            }
        }
    }

    /// Registers a live subscriber atomically with the replay hand-off: under one lock it delivers
    /// any events appended after the replay snapshot (so a subscriber attaching mid-reply misses
    /// nothing) and installs the continuation. The `Task.isCancelled` guard drops a continuation
    /// whose consumer already terminated during replay — `onTermination` cancels the task before
    /// removing the token, so a cancelled task never leaves a stale continuation in the dictionary.
    private func registerLiveContinuation(
        _ continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation,
        token: UUID, sessionID: String, deliveringAppendedAfter snapshotAppendedCount: Int
    ) {
        mutable.withLock { state in
            guard !Task.isCancelled else { return }
            let appended = state.appendedEvents[sessionID] ?? []
            for step in appended.dropFirst(snapshotAppendedCount) {
                continuation.yield(step.event)
            }
            state.continuations[sessionID, default: [:]][token] = continuation
        }
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] {
        openQuestions(in: fullLog(for: sessionID))
    }

    /// Mirrors a Claude-style ask, where the question is an unanswered tool call
    /// in the transcript rather than a pushed request. Opt in per instance so the
    /// opencode-shaped scripts keep exercising the event path.
    public func pendingQuestions(
        in messages: [ChatMessage], sessionID: String
    ) -> [QuestionRequest] {
        guard derivesQuestionsFromTranscript else { return [] }
        return QuestionRequest.awaitingAnswer(in: messages, sessionID: sessionID)
    }

    public func listFiles(path: String?) async throws -> [FileNode] {
        fileTree[path ?? "."] ?? fileTree[path ?? ""] ?? []
    }

    public func fileContent(path: String) async throws -> String { fileContents[path] ?? "" }

    public func gitSnapshot(directory: String?, sessionID: String?) async throws -> GitSnapshot? {
        git
    }

    public func gitPatch(directory: String?, sessionID: String?, path: String, staged: Bool)
        async throws -> GitPatch?
    {
        guard let patch = gitPatches[path] else { return nil }
        return GitPatch(path: path, staged: staged, patch: patch)
    }

    public func gitCommit(directory: String?, sessionID: String?, hash: String) async throws
        -> GitCommitDetail?
    {
        guard let commit = git?.commits.first(where: { $0.hash == hash || $0.short == hash })
        else { return nil }
        return GitCommitDetail(
            hash: commit.hash, short: commit.short, subject: commit.subject, author: commit.author,
            at: commit.at, refs: commit.refs)
    }
    public func diff(sessionID: String) async throws -> [FileDiff] { diffs }

    public func find(pattern: String) async throws -> [String] {
        let lowered = pattern.lowercased()
        return fileTree.values.flatMap { $0 }
            .filter { !$0.isDirectory && $0.path.lowercased().contains(lowered) }
            .map(\.path)
    }

    public func providers() async throws -> [Provider] {
        [Provider(id: "mock", name: "Mock", models: models, defaultModelID: models.first?.id)]
    }

    public func availableModels() async throws -> [ModelInfo] {
        let failures = mutable.withLock { mutable in
            let owed = mutable.modelsFailures
            mutable.modelsFailures = max(0, owed - 1)
            return owed
        }
        if failures > 0 { throw BackendFailure(message: "mock failure", retryable: true) }
        return models
    }

    public func defaultModel() async throws -> ModelSelection? {
        if let defaultModelID, let match = models.first(where: { $0.id == defaultModelID }) {
            return match.selection
        }
        return models.first?.selection
    }

    public var reasoningEffortOptions: [String] { effortOptions }
    public func setReasoningEffort(_ level: String) async throws {}
    public func applyModelSelection(_ model: ModelSelection) async throws {}

    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? { usage }
    public func usageAnalytics(days: Int) async throws -> UsageAnalyticsReport? { analytics }
    public func usageQuota() async throws -> UsageQuota? { quota }
    public func additionalUsageQuotas() async throws -> [UsageQuota] { additionalQuotas }

    /// Scoped per session when a fixture says which conversation spawned what,
    /// so a demo session that spawned nothing reports nothing.
    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        subagentOwners.isEmpty ? subagentSummaries : (subagentOwners[sessionID] ?? [])
    }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        guard let steps = subagentScripts[agentID] else {
            throw AgentError.unsupported("subagents")
        }
        var reducer = MessageReducer(agentType: agentType)
        for step in steps { reducer.apply(step.event) }
        return reducer.snapshot
    }

    private func baseScript(for sessionID: String) -> [MockScriptStep] {
        scripts[sessionID] ?? script
    }

    private func fullLog(for sessionID: String) -> [MockScriptStep] {
        replaySnapshot(for: sessionID).log
    }

    /// Snapshots the session's replay log together with the count of already-appended live steps,
    /// under a single lock, so a subscriber can later deliver exactly the steps appended after the
    /// snapshot without gaps or duplicates.
    private func replaySnapshot(for sessionID: String) -> (log: [MockScriptStep], appendedCount: Int)
    {
        mutable.withLock { state in
            let appended = state.appendedEvents[sessionID] ?? []
            let base = state.cleared.contains(sessionID) ? [] : baseScript(for: sessionID)
            return (base + appended, appended.count)
        }
    }

    /// Folds a session log into the questions the agent is still waiting on, matching how a real
    /// backend reports open questions: each `.question` stays pending until a matching
    /// `.questionResolved` (emitted by `answerQuestion`/`rejectQuestion` in interactive mode) clears it.
    private func openQuestions(in log: [MockScriptStep]) -> [QuestionRequest] {
        var open: [QuestionRequest] = []
        for step in log {
            switch step.event {
            case .question(let request):
                if !open.contains(where: { $0.id == request.id }) { open.append(request) }
            case .questionResolved(let requestID):
                open.removeAll { $0.id == requestID }
            default:
                break
            }
        }
        return open
    }

    /// Streams steps to the session's live subscribers with per-step delays, recording each into
    /// the session's appended log so `messages(for:)` and later subscriptions replay them.
    private func stream(_ steps: [MockScriptStep], to sessionID: String) {
        Task { [weak self] in
            for step in steps {
                guard let self else { return }
                try? await Task.sleep(for: step.delay)
                let targets = self.mutable.withLock { state in
                    state.appendedEvents[sessionID, default: []].append(step)
                    return Array((state.continuations[sessionID] ?? [:]).values)
                }
                for continuation in targets { continuation.yield(step.event) }
            }
        }
    }

    /// Rewrites message ids with a per-turn suffix (and fresh dates on upserts) so a cycled reply
    /// script never collides with its previous use in the reducer.
    private static func retagged(_ steps: [MockScriptStep], suffix: String) -> [MockScriptStep] {
        steps.map { step in
            let event: BackendEvent
            switch step.event {
            case .messageUpserted(let message, let replaceParts):
                event = .messageUpserted(
                    ChatMessage(
                        id: message.id + suffix, role: message.role, agentType: message.agentType,
                        parts: message.parts, createdAt: Date(), completedAt: message.completedAt,
                        isStreaming: message.isStreaming, error: message.error,
                        costUSD: message.costUSD, providerID: message.providerID,
                        modelID: message.modelID, totalTokens: message.totalTokens,
                        usage: message.usage, context: message.context),
                    replaceParts: replaceParts)
            case .partUpserted(let messageID, let part):
                event = .partUpserted(messageID: messageID + suffix, part)
            case .partTextDelta(let messageID, let partID, let delta):
                event = .partTextDelta(messageID: messageID + suffix, partID: partID, delta: delta)
            case .partRemoved(let messageID, let partID):
                event = .partRemoved(messageID: messageID + suffix, partID: partID)
            case .messageRemoved(let messageID):
                event = .messageRemoved(messageID: messageID + suffix)
            default:
                event = step.event
            }
            return MockScriptStep(event, delay: step.delay)
        }
    }
}

extension MockBackend {
    /// Builds a backend that replays recorded opencode `/event` SSE `data:` payloads through the real decoder.
    public static func replayingOpenCode(
        _ dataPayloads: [String],
        sessionID: String,
        delay: Duration = .milliseconds(10)
    ) -> MockBackend {
        let events = dataPayloads.compactMap {
            OpenCodeEventDecoder.decode(SSEvent(id: nil, type: nil, data: $0), sessionID: sessionID)
        }
        return MockBackend(
            agentType: .openCode, script: events.map { MockScriptStep($0, delay: delay) })
    }

}
