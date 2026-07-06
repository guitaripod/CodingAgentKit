import AgentCore
import ClaudeCodeKit
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

/// A scriptable in-memory backend for previews and deterministic tests.
///
/// `events(for:)` replays `script` with per-step delays. When `failAfter` is set, the FIRST
/// subscription throws after that many events (simulating a mid-stream drop); later subscriptions
/// replay the full script — which is how the reconnect path is exercised.
public final class MockBackend: FileBrowsingBackend, Sendable {
    public let agentType: AgentType
    public let capabilities: BackendCapabilities

    private let script: [MockScriptStep]
    private let failAfter: Int?
    private let failure: BackendFailure
    private let sessions: [AgentSession]
    private let models: [ModelInfo]
    private let serverHealth: ServerHealth
    private let mutable = Mutex(Mutable())

    private struct Mutable {
        var subscriptions = 0
        var sentPrompts: [SendPrompt] = []
    }

    public init(
        agentType: AgentType = .openCode,
        script: [MockScriptStep] = [],
        failAfter: Int? = nil,
        failure: BackendFailure = BackendFailure(message: "mock failure", retryable: true),
        sessions: [AgentSession]? = nil,
        models: [ModelInfo] = [],
        health: ServerHealth = ServerHealth(healthy: true, version: "mock"),
        capabilities: BackendCapabilities? = nil
    ) {
        self.agentType = agentType
        self.script = script
        self.failAfter = failAfter
        self.failure = failure
        self.models = models
        self.serverHealth = health
        self.sessions =
            sessions
            ?? [
                AgentSession(
                    id: "mock", agentType: agentType, title: "Mock session",
                    createdAt: Date(timeIntervalSince1970: 0),
                    updatedAt: Date(timeIntervalSince1970: 0))
            ]
        self.capabilities =
            capabilities
            ?? BackendCapabilities(
                supportsFileBrowsing: true, supportsDiffs: true, supportsPermissions: true,
                supportsMultipleSessions: true, supportsModelSelection: true,
                supportsAttachments: true)
    }

    public var recordedPrompts: [SendPrompt] { mutable.withLock { $0.sentPrompts } }

    public func health() async throws -> ServerHealth { serverHealth }
    public func listSessions() async throws -> [AgentSession] { sessions }

    public func createSession(title: String?) async throws -> AgentSession {
        AgentSession(
            id: "mock", agentType: agentType, title: title ?? "Mock session",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        var reducer = MessageReducer(agentType: agentType)
        for step in script { reducer.apply(step.event) }
        return reducer.snapshot
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        mutable.withLock { $0.sentPrompts.append(prompt) }
    }

    public func abort(sessionID: String) async throws {}

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {}

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let failAt = mutable.withLock { state -> Int? in
            state.subscriptions += 1
            return state.subscriptions == 1 ? failAfter : nil
        }
        let script = script
        let failure = failure
        return AsyncThrowingStream { continuation in
            let task = Task {
                var count = 0
                for step in script {
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
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listFiles(path: String?) async throws -> [FileNode] { [] }
    public func fileContent(path: String) async throws -> String { "" }
    public func diff(sessionID: String) async throws -> [FileDiff] { [] }
    public func find(pattern: String) async throws -> [String] { [] }

    public func providers() async throws -> [Provider] {
        [Provider(id: "mock", name: "Mock", models: models, defaultModelID: models.first?.id)]
    }

    public func availableModels() async throws -> [ModelInfo] { models }
    public func defaultModel() async throws -> ModelSelection? { models.first?.selection }
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

    /// Builds a backend that replays recorded agentapi `/events` (event-type, data) pairs through the real decoder.
    public static func replayingClaude(
        _ typedEvents: [(type: String, data: String)],
        delay: Duration = .milliseconds(10)
    ) -> MockBackend {
        let events = typedEvents.compactMap {
            ClaudeCodeEventDecoder.decode(SSEvent(id: nil, type: $0.type, data: $0.data))
        }
        return MockBackend(
            agentType: .claudeCode, script: events.map { MockScriptStep($0, delay: delay) })
    }
}
