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

public struct ToolCall: Sendable, Hashable, Codable {
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

public struct FileReference: Sendable, Hashable, Codable {
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

public struct MessagePart: Identifiable, Sendable, Hashable, Codable {
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

extension MessagePart.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case tag
        case value
    }

    private enum Tag: String, Codable {
        case text
        case reasoning
        case tool
        case file
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .tag) {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .reasoning: self = .reasoning(try container.decode(String.self, forKey: .value))
        case .tool: self = .tool(try container.decode(ToolCall.self, forKey: .value))
        case .file: self = .file(try container.decode(FileReference.self, forKey: .value))
        case .unknown: self = .unknown(type: try container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode(Tag.text, forKey: .tag)
            try container.encode(value, forKey: .value)
        case .reasoning(let value):
            try container.encode(Tag.reasoning, forKey: .tag)
            try container.encode(value, forKey: .value)
        case .tool(let value):
            try container.encode(Tag.tool, forKey: .tag)
            try container.encode(value, forKey: .value)
        case .file(let value):
            try container.encode(Tag.file, forKey: .tag)
            try container.encode(value, forKey: .value)
        case .unknown(let type):
            try container.encode(Tag.unknown, forKey: .tag)
            try container.encode(type, forKey: .value)
        }
    }
}

public struct ChatMessage: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public var role: MessageRole
    public let agentType: AgentType
    public var parts: [MessagePart]
    public var createdAt: Date
    public var completedAt: Date?
    public var isStreaming: Bool
    public var error: String?
    public var costUSD: Double?
    public var providerID: String?
    public var modelID: String?
    public var totalTokens: Int?

    public init(
        id: String,
        role: MessageRole,
        agentType: AgentType,
        parts: [MessagePart] = [],
        createdAt: Date,
        completedAt: Date? = nil,
        isStreaming: Bool = false,
        error: String? = nil,
        costUSD: Double? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        totalTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.agentType = agentType
        self.parts = parts
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.isStreaming = isStreaming
        self.error = error
        self.costUSD = costUSD
        self.providerID = providerID
        self.modelID = modelID
        self.totalTokens = totalTokens
    }

    public var text: String {
        parts.compactMap { part in
            if case .text(let value) = part.kind { return value }
            return nil
        }.joined()
    }
}
