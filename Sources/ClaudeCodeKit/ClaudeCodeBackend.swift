import AgentCore
import Foundation

public struct ClaudeCodeBackend: PollingBackend {
    public static let sessionID = "agentapi"

    public let agentType: AgentType = .claudeCode
    public let capabilities = BackendCapabilities(
        supportsFileBrowsing: false,
        supportsDiffs: false,
        supportsPermissions: false,
        supportsMultipleSessions: false,
        supportsModelSelection: true,
        supportsAttachments: false,
        supportsReasoningEffort: true,
        supportsClearing: true
    )

    /// Claude Code model aliases accepted by the `/model` command, newest first.
    public static let models: [ModelInfo] = [
        ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
        ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic"),
        ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic"),
    ]

    public var reasoningEffortOptions: [String] { ["low", "medium", "high"] }

    let client: AgentAPIClient

    public init(config: ServerConfig) {
        self.client = AgentAPIClient(config: config)
    }

    public init(client: AgentAPIClient) {
        self.client = client
    }

    public func health() async throws -> ServerHealth {
        let status = try await client.status()
        return ServerHealth(healthy: true, version: status.agentType)
    }

    public func agentStatus() async throws -> ClaudeAgentStatus {
        let status = try await client.status()
        return ClaudeAgentStatus(
            agentType: status.agentType,
            status: ClaudeCodeMapping.status(status.status),
            transport: status.transport
        )
    }

    public func listSessions() async throws -> [AgentSession] {
        [session(title: "Claude Code")]
    }

    public func createSession(title: String?) async throws -> AgentSession {
        try? await client.sendMessage(content: "/clear", type: "user")
        return session(title: title ?? "Claude Code")
    }

    public func clearConversation(_ sessionID: String) async throws {
        try await client.sendMessage(content: "/clear", type: "user")
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await client.messages().map(ClaudeCodeMapping.message)
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        try await client.sendMessage(content: prompt.text)
    }

    public func availableModels() async throws -> [ModelInfo] { Self.models }

    public func defaultModel() async throws -> ModelSelection? { nil }

    public func applyModelSelection(_ model: ModelSelection) async throws {
        try await client.sendMessage(content: "/model \(model.modelID)", type: "user")
    }

    public func setReasoningEffort(_ level: String) async throws {
        try await client.sendMessage(content: "/effort \(level)", type: "user")
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let raw = client.eventStream()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await sse in raw {
                        if let event = ClaudeCodeEventDecoder.decode(sse) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func pollingEvents(for sessionID: String, interval: Duration = .seconds(1))
        -> AsyncThrowingStream<BackendEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var lastContent: [String: String] = [:]
                var lastStatus: BackendStatus?
                do {
                    while !Task.isCancelled {
                        for message in try await client.messages() {
                            let chat = ClaudeCodeMapping.message(message)
                            if lastContent[chat.id] != chat.text {
                                lastContent[chat.id] = chat.text
                                continuation.yield(.messageUpserted(chat, replaceParts: true))
                            }
                        }
                        let status = ClaudeCodeMapping.status(try await client.status().status)
                        if status != lastStatus {
                            lastStatus = status
                            continuation.yield(.status(status))
                        }
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func session(title: String) -> AgentSession {
        let now = Date()
        return AgentSession(
            id: Self.sessionID,
            agentType: .claudeCode,
            title: title,
            createdAt: now,
            updatedAt: now
        )
    }
}
