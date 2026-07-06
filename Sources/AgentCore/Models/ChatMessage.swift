import Foundation

public enum MessageRole: String, Sendable, Hashable, Codable {
    case user
    case assistant
    case system
}

public enum ToolStatus: String, Sendable, Hashable, Codable {
    case pending
    case running
    case completed
    case error
}

public struct ToolCall: Sendable, Hashable {
    public let id: String
    public var name: String
    public var status: ToolStatus
    public var input: JSONValue?
    public var output: String?
    public var title: String?

    public init(
        id: String,
        name: String,
        status: ToolStatus,
        input: JSONValue? = nil,
        output: String? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.input = input
        self.output = output
        self.title = title
    }
}

public struct FileReference: Sendable, Hashable {
    public var path: String?
    public var mime: String?
    public var url: String?
    public var filename: String?

    public init(
        path: String? = nil, mime: String? = nil, url: String? = nil, filename: String? = nil
    ) {
        self.path = path
        self.mime = mime
        self.url = url
        self.filename = filename
    }
}

public struct MessagePart: Identifiable, Sendable, Hashable {
    public let id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Sendable, Hashable {
        case text(String)
        case reasoning(String)
        case tool(ToolCall)
        case file(FileReference)
        case unknown(type: String)
    }

    public var text: String? {
        switch kind {
        case .text(let value), .reasoning(let value): return value
        default: return nil
        }
    }

    public mutating func appendText(_ delta: String) {
        switch kind {
        case .text(let value): kind = .text(value + delta)
        case .reasoning(let value): kind = .reasoning(value + delta)
        default: break
        }
    }
}

public struct ChatMessage: Identifiable, Sendable, Hashable {
    public let id: String
    public var role: MessageRole
    public let agentType: AgentType
    public var parts: [MessagePart]
    public var createdAt: Date
    public var completedAt: Date?
    public var isStreaming: Bool
    public var error: String?

    public init(
        id: String,
        role: MessageRole,
        agentType: AgentType,
        parts: [MessagePart] = [],
        createdAt: Date,
        completedAt: Date? = nil,
        isStreaming: Bool = false,
        error: String? = nil
    ) {
        self.id = id
        self.role = role
        self.agentType = agentType
        self.parts = parts
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.isStreaming = isStreaming
        self.error = error
    }

    public var text: String {
        parts.compactMap { part in
            if case .text(let value) = part.kind { return value }
            return nil
        }.joined()
    }
}
