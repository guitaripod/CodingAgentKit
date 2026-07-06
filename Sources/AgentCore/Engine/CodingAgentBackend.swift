public struct BackendCapabilities: Sendable, Hashable {
    public var supportsFileBrowsing: Bool
    public var supportsDiffs: Bool
    public var supportsPermissions: Bool
    public var supportsMultipleSessions: Bool
    public var supportsModelSelection: Bool

    public init(
        supportsFileBrowsing: Bool,
        supportsDiffs: Bool,
        supportsPermissions: Bool,
        supportsMultipleSessions: Bool,
        supportsModelSelection: Bool
    ) {
        self.supportsFileBrowsing = supportsFileBrowsing
        self.supportsDiffs = supportsDiffs
        self.supportsPermissions = supportsPermissions
        self.supportsMultipleSessions = supportsMultipleSessions
        self.supportsModelSelection = supportsModelSelection
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

public enum BackendStatus: String, Sendable, Hashable {
    case idle
    case running
    case stable
    case unknown
}

public struct PermissionRequest: Sendable, Hashable {
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
    case failure(String)
    case unknown(type: String)
}

public protocol CodingAgentBackend: Sendable {
    var agentType: AgentType { get }
    var capabilities: BackendCapabilities { get }

    func health() async throws -> ServerHealth
    func listSessions() async throws -> [AgentSession]
    func createSession(title: String?) async throws -> AgentSession
    func messages(for sessionID: String) async throws -> [ChatMessage]
    func send(_ prompt: SendPrompt, to sessionID: String) async throws
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error>
    func abort(sessionID: String) async throws
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
}

extension CodingAgentBackend {
    public func abort(sessionID: String) async throws {
        throw AgentError.unsupported("abort")
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        throw AgentError.unsupported("permissions")
    }
}

public protocol FileBrowsingBackend: CodingAgentBackend {
    func listFiles(path: String?) async throws -> [FileNode]
    func fileContent(path: String) async throws -> String
    func diff(sessionID: String) async throws -> [FileDiff]
    func find(pattern: String) async throws -> [String]
    func providers() async throws -> [Provider]
}
