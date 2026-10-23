import Foundation

/// What a queued prompt carried besides its words. Metadata only: the bytes travel once, with the
/// enqueue, and the server keeps them until the prompt starts.
public struct QueuedAttachment: Sendable, Hashable, Codable {
    public var mime: String
    public var filename: String?
    /// The size in bytes where the server said one.
    public var size: Int?

    public init(mime: String, filename: String? = nil, size: Int? = nil) {
        self.mime = mime
        self.filename = filename
        self.size = size
    }
}

/// A message waiting on the server behind a running turn, which every client of the conversation
/// sees and can edit or cancel. It is not in the transcript: its user message is written when the
/// server starts it.
public struct QueuedPrompt: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case prompt
        /// A slash command such as `/compact`.
        case command
    }

    /// Chosen by the client that enqueued it, so that asking again with the same id changes
    /// nothing on the server.
    public var id: String
    public var text: String
    public var kind: Kind
    /// The model the item starts with, as the server names it; nil leaves the session's own.
    public var model: String?
    /// The reasoning level the item starts with; nil leaves the session's own.
    public var effort: String?
    public var attachments: [QueuedAttachment]
    public var createdAt: Date

    public init(
        id: String, text: String, kind: Kind = .prompt, model: String? = nil,
        effort: String? = nil, attachments: [QueuedAttachment] = [], createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.model = model
        self.effort = effort
        self.attachments = attachments
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, kind, model, effort, attachments, createdAt
    }

    /// A kind this client does not know reads as a plain prompt, and a cached item written before
    /// a field existed decodes without it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        kind =
            (try container.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init)
            ?? .prompt
        model = try container.decodeIfPresent(String.self, forKey: .model)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        attachments =
            try container.decodeIfPresent([QueuedAttachment].self, forKey: .attachments) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
    }
}

/// The server's queue for one conversation, in arrival order.
public struct QueueSnapshot: Sendable, Hashable, Codable {
    public var items: [QueuedPrompt]
    /// True after a Stop: the items stay, and nothing starts until a new message or a resume.
    public var paused: Bool

    public init(items: [QueuedPrompt] = [], paused: Bool = false) {
        self.items = items
        self.paused = paused
    }

    public static let empty = QueueSnapshot()

    public var isEmpty: Bool { items.isEmpty }
}

/// A prompt handed to the server's queue: the words and settings of a send, under an id the
/// server uses to recognise a retry.
public struct EnqueuePrompt: Sendable, Hashable {
    public var id: String
    public var kind: QueuedPrompt.Kind
    public var prompt: SendPrompt

    public init(id: String = UUID().uuidString, kind: QueuedPrompt.Kind = .prompt, prompt: SendPrompt) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
    }
}

/// What the server did with an enqueue.
public struct EnqueueResult: Sendable, Hashable {
    /// True when nothing was running and the prompt started at once. It never appears in the
    /// queue then.
    public var started: Bool
    public var queue: QueueSnapshot

    public init(started: Bool, queue: QueueSnapshot = .empty) {
        self.started = started
        self.queue = queue
    }
}

/// The fields of a queued prompt that can still be changed; nil leaves a field as it is.
public struct QueuedPromptEdit: Sendable, Hashable {
    public var text: String?
    public var model: ModelSelection?
    public var reasoningEffort: String?

    public init(text: String? = nil, model: ModelSelection? = nil, reasoningEffort: String? = nil) {
        self.text = text
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

/// Why a change to the queue was refused.
public enum QueueError: Error, Sendable, Equatable {
    /// The prompt started, or is gone, so it can no longer be edited or cancelled.
    case alreadyStarted
}

extension QueueError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return AgentText.string("This message already started, so it can no longer be changed.")
        }
    }
}
