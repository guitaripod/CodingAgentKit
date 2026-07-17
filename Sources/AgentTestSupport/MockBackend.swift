import AgentCore
import Foundation
import OpenCodeKit
import Synchronization

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
public final class MockBackend: FileBrowsingBackend, Sendable {
    public let agentType: AgentType
    public let capabilities: BackendCapabilities

    private let script: [MockScriptStep]
    private let scripts: [String: [MockScriptStep]]
    private let replyTurns: [[MockScriptStep]]
    private let interactive: Bool
    private let failAfter: Int?
    private let failure: BackendFailure
    private let models: [ModelInfo]
    private let defaultModelID: String?
    private let effortOptions: [String]
    private let serverHealth: ServerHealth
    private let quota: UsageQuota?
    private let additionalQuotas: [UsageQuota]
    private let usage: AgentUsage?
    private let fileTree: [String: [FileNode]]
    private let fileContents: [String: String]
    private let diffs: [FileDiff]
    private let subagentSummaries: [SubagentSummary]
    private let subagentScripts: [String: [MockScriptStep]]
    private let mutable = Mutex(Mutable())

    private struct Mutable {
        var subscriptions = 0
        var sentPrompts: [SendPrompt] = []
        var sessions: [AgentSession] = []
        var appendedEvents: [String: [MockScriptStep]] = [:]
        var cleared: Set<String> = []
        var continuations: [String: [UUID: AsyncThrowingStream<BackendEvent, Error>.Continuation]] = [:]
        var replyIndex = 0
        var mintCounter = 0
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
        defaultModelID: String? = nil,
        reasoningEffortOptions: [String] = [],
        health: ServerHealth = ServerHealth(healthy: true, version: "mock"),
        capabilities: BackendCapabilities? = nil,
        quota: UsageQuota? = nil,
        additionalQuotas: [UsageQuota] = [],
        sessionUsage: AgentUsage? = nil,
        fileTree: [String: [FileNode]] = [:],
        fileContents: [String: String] = [:],
        diffs: [FileDiff] = [],
        subagents: [SubagentSummary] = [],
        subagentScripts: [String: [MockScriptStep]] = [:]
    ) {
        self.agentType = agentType
        self.script = script
        self.scripts = scripts
        self.replyTurns = replyTurns
        self.interactive = interactive
        self.failAfter = failAfter
        self.failure = failure
        self.models = models
        self.defaultModelID = defaultModelID
        self.effortOptions = reasoningEffortOptions
        self.serverHealth = health
        self.quota = quota
        self.additionalQuotas = additionalQuotas
        self.usage = sessionUsage
        self.fileTree = fileTree
        self.fileContents = fileContents
        self.diffs = diffs
        self.subagentSummaries = subagents
        self.subagentScripts = subagentScripts
        self.capabilities =
            capabilities
            ?? BackendCapabilities(
                supportsFileBrowsing: true, supportsDiffs: true, supportsPermissions: true,
                supportsMultipleSessions: true, supportsModelSelection: true,
                supportsAttachments: true, supportsAbort: true, supportsSessionUsage: true,
                supportsQuestions: true)
        mutable.withLock {
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

    public var recordedPrompts: [SendPrompt] { mutable.withLock { $0.sentPrompts } }

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
        for step in fullLog(for: sessionID) { reducer.apply(step.event) }
        return reducer.snapshot
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        let turn: [MockScriptStep]? = mutable.withLock { state in
            state.sentPrompts.append(prompt)
            guard interactive else { return nil }
            var steps: [MockScriptStep] = []
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
        guard interactive else { return }
        stream([MockScriptStep(.status(.idle), delay: .zero)], to: sessionID)
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

    public func listFiles(path: String?) async throws -> [FileNode] {
        fileTree[path ?? "."] ?? fileTree[path ?? ""] ?? []
    }

    public func fileContent(path: String) async throws -> String { fileContents[path] ?? "" }
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

    public func availableModels() async throws -> [ModelInfo] { models }

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
    public func usageQuota() async throws -> UsageQuota? { quota }
    public func additionalUsageQuotas() async throws -> [UsageQuota] { additionalQuotas }

    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        subagentSummaries
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
                        modelID: message.modelID, totalTokens: message.totalTokens),
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
