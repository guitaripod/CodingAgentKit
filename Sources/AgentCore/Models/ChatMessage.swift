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
        case compaction(Compaction)
        case unknown(type: String)
    }

    public var text: String? {
        switch kind {
        case .text(let value), .reasoning(let value): return value
        default: return nil
        }
    }

    /// Adds what just arrived to what is already here.
    ///
    /// `value + delta` reads well and allocates the whole answer again for every token, because
    /// the case still holds the original while the sum is being built — an answer of a hundred
    /// thousand characters arriving in two thousand lumps copies a hundred million characters, all
    /// of it garbage. Taking the string out of the case first leaves it uniquely referenced, so
    /// appending grows the buffer it already has.
    public mutating func appendText(_ delta: String) {
        switch kind {
        case .text(var value):
            kind = .text("")
            value += delta
            kind = .text(value)
        case .reasoning(var value):
            kind = .reasoning("")
            value += delta
            kind = .reasoning(value)
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
        case compaction
        case unknown
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Tag.self, forKey: .tag) {
        case .text: self = .text(try container.decode(String.self, forKey: .value))
        case .reasoning: self = .reasoning(try container.decode(String.self, forKey: .value))
        case .tool: self = .tool(try container.decode(ToolCall.self, forKey: .value))
        case .file: self = .file(try container.decode(FileReference.self, forKey: .value))
        case .compaction: self = .compaction(try container.decode(Compaction.self, forKey: .value))
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
        case .compaction(let value):
            try container.encode(Tag.compaction, forKey: .tag)
            try container.encode(value, forKey: .value)
        case .unknown(let type):
            try container.encode(Tag.unknown, forKey: .tag)
            try container.encode(type, forKey: .value)
        }
    }
}

/// What one turn actually consumed, split into the tiers that price and behave differently.
///
/// The split is the whole point of carrying it: a total says a turn was large, where the tiers say
/// what made it large — a long answer, a context read back out of cache for a tenth of the price,
/// or a cache written at a premium so the next turn is cheap. Only ``output`` is produced at the
/// model's own speed, so it is also the only tier a rate may be computed from; dividing a total by
/// a duration prices the wait for a prompt the model never wrote.
///
/// Absent means the server did not say. Zero means it said nothing was spent, which is a different
/// fact and belongs to answerless turns.
public struct MessageUsage: Sendable, Hashable, Codable {
    public var input: Int
    public var output: Int
    /// Thinking, where the server counts it apart from the answer. Providers that fold it into
    /// `output` leave this at zero rather than double-counting it.
    public var reasoning: Int
    public var cacheRead: Int
    public var cacheWrite: Int

    public init(
        input: Int = 0, output: Int = 0, reasoning: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0
    ) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var total: Int { input + output + reasoning + cacheRead + cacheWrite }

    /// Everything the model wrote, which is what a speed is measured against.
    public var written: Int { output + reasoning }

    /// Everything it was handed, however it was paid for.
    public var read: Int { input + cacheRead + cacheWrite }

    public var isEmpty: Bool { total == 0 }
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
    public var reasoningEffort: String?
    public var totalTokens: Int?
    /// The same tokens split by tier, where the server reports them that way. `totalTokens` stays
    /// the one number every existing surface reads; this is what a turn's own account is drawn
    /// from, and what a speed can honestly be computed against.
    public var usage: MessageUsage?
    /// How long the turn took, where the server measured it itself — from the moment the person
    /// pressed return to the last thing the turn wrote, which is the wait a person actually had.
    /// Nil where the server does not say and the stamps are all there is; never a substitute for
    /// ``completedAt``, which some backends do not stamp and whose absence means "still open".
    public var duration: TimeInterval?
    /// The backend's own word for how the turn ended, verbatim and never translated here — a
    /// client that shows it shows what the server said.
    public var finishReason: String?

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
        reasoningEffort: String? = nil,
        totalTokens: Int? = nil,
        usage: MessageUsage? = nil,
        duration: TimeInterval? = nil,
        finishReason: String? = nil
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
        self.reasoningEffort = reasoningEffort
        self.totalTokens = totalTokens
        self.usage = usage
        self.duration = duration
        self.finishReason = finishReason
    }

    public var text: String {
        parts.compactMap { part in
            if case .text(let value) = part.kind { return value }
            return nil
        }.joined()
    }

    /// Whether this message holds anything a reader would call an answer: words, a thought, a
    /// tool call, a picture, a seam. Step markers are the turn's own bookkeeping and carry
    /// nothing, so a message made only of them holds nothing at all.
    public var carriesAnswer: Bool {
        parts.contains { part in
            switch part.kind {
            case .text(let value), .reasoning(let value):
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool, .file, .compaction:
                return true
            case .unknown:
                return false
            }
        }
    }

    /// A turn that finished and said nothing — no words, no tool, and no error to explain it.
    ///
    /// It is a real outcome rather than a rendering accident: a provider that refuses a request
    /// mid-stream can end a turn with a finish reason it has no word for, zero tokens and not one
    /// content part, and everything downstream then has nothing to draw. Left unnamed the whole
    /// turn is invisible — the sender watches a spinner disappear and the transcript sit exactly
    /// as it was — so it is named here, once, for every client to say out loud.
    ///
    /// A turn somebody stopped by hand is excluded: that person already knows why it is empty.
    public var isAnswerless: Bool {
        guard role == .assistant, !isStreaming, completedAt != nil else { return false }
        guard error == nil, !carriesAnswer else { return false }
        return !Self.haltedByHand.contains(finishReason?.lowercased() ?? "")
    }

    private static let haltedByHand: Set<String> = [
        "abort", "aborted", "cancel", "cancelled", "canceled", "interrupt", "interrupted", "stop-by-user",
    ]
}
