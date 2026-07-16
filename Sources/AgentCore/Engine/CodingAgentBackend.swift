import Foundation

public struct BackendCapabilities: Sendable, Hashable {
    public var supportsFileBrowsing: Bool
    public var supportsDiffs: Bool
    public var supportsPermissions: Bool
    public var supportsMultipleSessions: Bool
    public var supportsModelSelection: Bool
    public var supportsAttachments: Bool
    public var supportsReasoningEffort: Bool
    public var supportsClearing: Bool
    public var supportsForking: Bool
    public var supportsAbort: Bool
    public var supportsSessionUsage: Bool
    public var supportsQuestions: Bool
    public var supportsRenaming: Bool
    public var supportsSubagents: Bool

    public init(
        supportsFileBrowsing: Bool,
        supportsDiffs: Bool,
        supportsPermissions: Bool,
        supportsMultipleSessions: Bool,
        supportsModelSelection: Bool,
        supportsAttachments: Bool,
        supportsReasoningEffort: Bool = false,
        supportsClearing: Bool = false,
        supportsForking: Bool = false,
        supportsAbort: Bool = false,
        supportsSessionUsage: Bool = false,
        supportsQuestions: Bool = false,
        supportsRenaming: Bool = false,
        supportsSubagents: Bool = false
    ) {
        self.supportsFileBrowsing = supportsFileBrowsing
        self.supportsDiffs = supportsDiffs
        self.supportsPermissions = supportsPermissions
        self.supportsMultipleSessions = supportsMultipleSessions
        self.supportsModelSelection = supportsModelSelection
        self.supportsAttachments = supportsAttachments
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsClearing = supportsClearing
        self.supportsForking = supportsForking
        self.supportsAbort = supportsAbort
        self.supportsSessionUsage = supportsSessionUsage
        self.supportsQuestions = supportsQuestions
        self.supportsRenaming = supportsRenaming
        self.supportsSubagents = supportsSubagents
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

/// Live subscription quota for a provider (Claude Max/Pro rolling rate limits), sourced from the
/// provider's own usage API rather than estimated from message costs.
public struct UsageQuota: Sendable, Hashable, Codable {
    public struct Gauge: Sendable, Hashable, Codable {
        public var key: String
        public var label: String
        public var fraction: Double
        public var resetsAt: Date?
        public var trustedReset: Bool

        public init(key: String, label: String, fraction: Double, resetsAt: Date?, trustedReset: Bool) {
            self.key = key
            self.label = label
            self.fraction = fraction
            self.resetsAt = resetsAt
            self.trustedReset = trustedReset
        }
    }

    public struct Detail: Sendable, Hashable, Codable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var providerName: String
    public var subtitle: String
    public var source: String
    public var live: Bool
    public var gauges: [Gauge]
    public var details: [Detail]

    public init(
        providerName: String, subtitle: String, source: String, live: Bool,
        gauges: [Gauge], details: [Detail]
    ) {
        self.providerName = providerName
        self.subtitle = subtitle
        self.source = source
        self.live = live
        self.gauges = gauges
        self.details = details
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
    public var detail: String?

    public init(message: String, code: String? = nil, retryable: Bool = false, detail: String? = nil) {
        self.message = message
        self.code = code
        self.retryable = retryable
        self.detail = detail
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

/// A structured question the agent asks mid-turn (opencode's question tool):
/// one request can carry several questions, each with predefined options,
/// optional multi-select, and optional free-form ("custom") answers.
public struct QuestionRequest: Sendable, Hashable, Codable, Identifiable {
    public struct Option: Sendable, Hashable, Codable {
        public let label: String
        public let description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public struct Item: Sendable, Hashable, Codable {
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiple: Bool
        public let custom: Bool

        public init(
            question: String, header: String, options: [Option],
            multiple: Bool = false, custom: Bool = false
        ) {
            self.question = question
            self.header = header
            self.options = options
            self.multiple = multiple
            self.custom = custom
        }
    }

    public let id: String
    public var sessionID: String
    public var questions: [Item]

    public init(id: String, sessionID: String, questions: [Item]) {
        self.id = id
        self.sessionID = sessionID
        self.questions = questions
    }
}

public enum BackendEvent: Sendable {
    case messageUpserted(ChatMessage, replaceParts: Bool)
    case partUpserted(messageID: String, MessagePart)
    case partTextDelta(messageID: String, partID: String, delta: String)
    case partRemoved(messageID: String, partID: String)
    case messageRemoved(messageID: String)
    case status(BackendStatus)
    case permission(PermissionRequest)
    case question(QuestionRequest)
    case questionResolved(requestID: String)
    case failure(BackendFailure)
    case unknown(type: String)
}

/// A coding-agent server behind one unified surface. Conformers translate their wire protocol
/// into ``BackendEvent`` values a ``MessageReducer`` folds.
public protocol CodingAgentBackend: Sendable {
    var agentType: AgentType { get }
    var capabilities: BackendCapabilities { get }

    func health() async throws -> ServerHealth
    func listSessions() async throws -> [AgentSession]
    func createSession(title: String?, directory: String?) async throws -> AgentSession
    func deleteSession(_ sessionID: String) async throws
    func messages(for sessionID: String) async throws -> [ChatMessage]
    func send(_ prompt: SendPrompt, to sessionID: String) async throws
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error>
    func abort(sessionID: String) async throws
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    /// Answers a pending question request: one answer array per question, in
    /// order, each holding the selected option labels (or a custom string).
    func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws
    func rejectQuestion(_ request: QuestionRequest) async throws
    /// Questions currently blocking a turn — used to recover state after a
    /// reconnect, since the asked event is not replayed. Empty when
    /// unsupported.
    func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest]
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
    /// Live subscription quota (rolling rate-limit gauges) for the whole account, if the backend
    /// exposes a usage API. `nil` when unsupported.
    func usageQuota() async throws -> UsageQuota?
    /// Live quotas for other providers the backend's host machine is signed into (the bridge
    /// serves Grok's billing quota alongside Claude's). Empty when unsupported.
    func additionalUsageQuotas() async throws -> [UsageQuota]
    /// Branches a session into a new one seeded with the same history, so the next prompt explores a
    /// different direction without disturbing the original (Claude Code resumes with `--fork-session`).
    func forkSession(_ sessionID: String) async throws -> AgentSession
    /// Renames a session's display title.
    func renameSession(_ sessionID: String, title: String) async throws
    /// Subagents spawned within a session (Claude Code sidecar transcripts). Empty when unsupported.
    func subagents(for sessionID: String) async throws -> [SubagentSummary]
    /// A subagent's full transcript, rendered in the same message model as the session itself.
    func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage]
}

extension CodingAgentBackend {
    public func abort(sessionID: String) async throws {
        throw AgentError.unsupported("abort")
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        throw AgentError.unsupported("permissions")
    }

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        throw AgentError.unsupported("questions")
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        throw AgentError.unsupported("questions")
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] { [] }

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
    public func usageQuota() async throws -> UsageQuota? { nil }
    public func additionalUsageQuotas() async throws -> [UsageQuota] { [] }
    public func forkSession(_ sessionID: String) async throws -> AgentSession {
        throw AgentError.unsupported("fork")
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        throw AgentError.unsupported("rename")
    }

    public func subagents(for sessionID: String) async throws -> [SubagentSummary] { [] }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        throw AgentError.unsupported("subagents")
    }
}

public protocol FileBrowsingBackend: CodingAgentBackend {
    func listFiles(path: String?) async throws -> [FileNode]
    func fileContent(path: String) async throws -> String
    func diff(sessionID: String) async throws -> [FileDiff]
    func find(pattern: String) async throws -> [String]
    func providers() async throws -> [Provider]
}
