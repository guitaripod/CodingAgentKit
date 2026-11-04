import Foundation

/// What fills a conversation's context window, measured by the agent itself rather than estimated
/// from the transcript: the system prompt, tool definitions, memory files and skills it loaded,
/// what each kind of message weighs, the window it is measured against and where it starts to
/// compact on its own.
public struct MeasuredContext: Sendable, Hashable, Codable {
    public struct Category: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var tokens: Int
        /// `used`, `deferred` (definitions loaded only when asked for), `buffer` (held back for
        /// compaction) or `free`; anything else a newer agent says is kept as it said it.
        public var kind: String

        public init(id: String, name: String, tokens: Int, kind: String) {
            self.id = id
            self.name = name
            self.tokens = tokens
            self.kind = kind
        }

        /// Whether the category is in the window now, as opposed to room or definitions not loaded.
        public var isUsed: Bool { kind == "used" }
    }

    public struct Messages: Sendable, Hashable, Codable {
        public var user: Int
        public var assistant: Int
        public var toolCalls: Int
        public var toolResults: Int
        public var attachments: Int
        public var other: Int

        public init(user: Int, assistant: Int, toolCalls: Int, toolResults: Int, attachments: Int, other: Int) {
            self.user = user
            self.assistant = assistant
            self.toolCalls = toolCalls
            self.toolResults = toolResults
            self.attachments = attachments
            self.other = other
        }
    }

    public struct MemoryFile: Sendable, Hashable, Codable {
        public var path: String
        public var tokens: Int

        public init(path: String, tokens: Int) {
            self.path = path
            self.tokens = tokens
        }
    }

    public var model: String?
    public var totalTokens: Int
    public var maxTokens: Int
    public var autoCompactAt: Int?
    public var categories: [Category]
    public var messages: Messages?
    public var memoryFiles: [MemoryFile]
    public var measuredAt: Date

    public init(
        model: String?, totalTokens: Int, maxTokens: Int, autoCompactAt: Int?,
        categories: [Category], messages: Messages?, memoryFiles: [MemoryFile], measuredAt: Date
    ) {
        self.model = model
        self.totalTokens = totalTokens
        self.maxTokens = maxTokens
        self.autoCompactAt = autoCompactAt
        self.categories = categories
        self.messages = messages
        self.memoryFiles = memoryFiles
        self.measuredAt = measuredAt
    }
}

/// A backend that can ask its agent what fills a conversation's window. `nil` is *cannot say* —
/// a conversation the agent has no transcript for, or a server too old for the question — never
/// an empty window.
public protocol ContextMeasuring: Sendable {
    func measuredContext(for sessionID: String) async throws -> MeasuredContext?
}
