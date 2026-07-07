public struct BackendCapabilities: Sendable, Hashable {
    public var supportsFileBrowsing: Bool
    public var supportsDiffs: Bool
    public var supportsPermissions: Bool
    public var supportsMultipleSessions: Bool
    public var supportsModelSelection: Bool
    public var supportsAttachments: Bool
    public var supportsReasoningEffort: Bool
    public var supportsClearing: Bool

    public init(
        supportsFileBrowsing: Bool,
        supportsDiffs: Bool,
        supportsPermissions: Bool,
        supportsMultipleSessions: Bool,
        supportsModelSelection: Bool,
        supportsAttachments: Bool,
        supportsReasoningEffort: Bool = false,
        supportsClearing: Bool = false
    ) {
        self.supportsFileBrowsing = supportsFileBrowsing
        self.supportsDiffs = supportsDiffs
        self.supportsPermissions = supportsPermissions
        self.supportsMultipleSessions = supportsMultipleSessions
        self.supportsModelSelection = supportsModelSelection
        self.supportsAttachments = supportsAttachments
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsClearing = supportsClearing
    }
}

public struct AgentUsage: Sendable, Hashable, Codable {
    public var costUSD: Double?
    public var tokens: Int?

    public init(costUSD: Double? = nil, tokens: Int? = nil) {
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

public struct ServerHealth: Sendable, Hashable {
    public var healthy: Bool
    public var version: String?

    public init(healthy: Bool, version: String? = nil) {
        self.healthy = healthy
        self.version = version
    }
}

public enum BackendStatus: String, Sendable, Hashable, Codable {
    case idle
    case running
    case stable
    case unknown
}

public struct BackendFailure: Error, Sendable, Hashable, Codable {
    public var message: String
    public var code: String?
    public var retryable: Bool

    public init(message: String, code: String? = nil, retryable: Bool = false) {
        self.message = message
        self.code = code
        self.retryable = retryable
    }
}

public struct PermissionRequest: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var sessionID: String
    public var title: String?
    public var toolName: String?

    public init(id: String, sessionID: String, title: String? = nil, toolName: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.toolName = toolName
    }
}

public enum PermissionDecision: String, Sendable {
    case once
    case always
    case reject
}

public enum BackendEvent: Sendable {
    case messageUpserted(ChatMessage, replaceParts: Bool)
    case partUpserted(messageID: String, MessagePart)
    case partTextDelta(messageID: String, partID: String, delta: String)
    case partRemoved(messageID: String, partID: String)
    case messageRemoved(messageID: String)
    case status(BackendStatus)
    case permission(PermissionRequest)
    case failure(BackendFailure)
    case unknown(type: String)
}

/// A coding-agent server behind one unified surface. Conformers (opencode, Claude Code via
/// agentapi) translate their wire protocol into ``BackendEvent`` values a ``MessageReducer`` folds.
public protocol CodingAgentBackend: Sendable {
    var agentType: AgentType { get }
    var capabilities: BackendCapabilities { get }

    func health() async throws -> ServerHealth
    func listSessions() async throws -> [AgentSession]
    func createSession(title: String?) async throws -> AgentSession
    func deleteSession(_ sessionID: String) async throws
    func messages(for sessionID: String) async throws -> [ChatMessage]
    func send(_ prompt: SendPrompt, to sessionID: String) async throws
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error>
    func abort(sessionID: String) async throws
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    func availableModels() async throws -> [ModelInfo]
    func availableAgents() async throws -> [String]
    func defaultModel() async throws -> ModelSelection?

    /// Reasoning-effort levels a conformer supports (e.g. Claude Code: low/medium/high). Empty if none.
    var reasoningEffortOptions: [String] { get }
    /// Applies a reasoning-effort level immediately (Claude Code sends a `/effort` control command).
    func setReasoningEffort(_ level: String) async throws
    /// Applies a model selection immediately, for backends where the model is a persistent session
    /// setting rather than a per-message parameter (Claude Code sends a `/model` control command).
    func applyModelSelection(_ model: ModelSelection) async throws
    /// Clears the conversation in place (Claude Code sends a `/clear` control command) for backends
    /// that keep a single long-lived session rather than discrete ones.
    func clearConversation(_ sessionID: String) async throws
    /// The last turn's cost/token usage for a session, if the backend reports it.
    func sessionUsage(_ sessionID: String) async throws -> AgentUsage?
}

extension CodingAgentBackend {
    public func abort(sessionID: String) async throws {
        throw AgentError.unsupported("abort")
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        throw AgentError.unsupported("permissions")
    }

    public func deleteSession(_ sessionID: String) async throws {
        throw AgentError.unsupported("deleteSession")
    }

    public func availableModels() async throws -> [ModelInfo] { [] }
    public func availableAgents() async throws -> [String] { [] }
    public func defaultModel() async throws -> ModelSelection? { nil }

    public var reasoningEffortOptions: [String] { [] }
    public func setReasoningEffort(_ level: String) async throws {
        throw AgentError.unsupported("reasoningEffort")
    }
    public func applyModelSelection(_ model: ModelSelection) async throws {}
    public func clearConversation(_ sessionID: String) async throws {
        throw AgentError.unsupported("clearConversation")
    }
    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? { nil }
}

public protocol FileBrowsingBackend: CodingAgentBackend {
    func listFiles(path: String?) async throws -> [FileNode]
    func fileContent(path: String) async throws -> String
    func diff(sessionID: String) async throws -> [FileDiff]
    func find(pattern: String) async throws -> [String]
    func providers() async throws -> [Provider]
}

/// A backend that can deliver events by polling when its SSE stream is unavailable.
public protocol PollingBackend: CodingAgentBackend {
    func pollingEvents(for sessionID: String, interval: Duration)
        -> AsyncThrowingStream<BackendEvent, Error>
}
