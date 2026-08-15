import AgentCore

struct OCHealth: Decodable, Sendable {
    let healthy: Bool
    let version: String?
}

struct OCTime: Decodable, Sendable {
    let created: Double?
    let updated: Double?
    let completed: Double?
}

struct OCProject: Decodable, Sendable {
    let id: String
    let worktree: String?
    let time: OCTime?
}

struct OCSession: Decodable, Sendable {
    let id: String
    let title: String?
    let parentID: String?
    let directory: String?
    let time: OCTime?
    let model: OCSessionModel?
}

/// The model a session last ran with, as the session record reports it. The server names the
/// model `id` here where a message names it `modelID`; both spellings are read so neither
/// version of the record loses the fact.
struct OCSessionModel: Decodable, Sendable {
    let id: String?
    let providerID: String?
    let variant: String?

    private enum CodingKeys: String, CodingKey {
        case id, providerID, variant, modelID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .modelID)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
    }
}

/// What a session is doing right now, as opencode's own status routes report it. Only sessions
/// with something in flight are listed — the server deletes the key when a turn settles — so an
/// id that is absent is a session with nothing running.
struct OCSessionStatus: Decodable, Sendable {
    let type: String
}

struct OCMessage: Decodable, Sendable {
    let id: String
    let sessionID: String
    let role: String
    let time: OCTime?
    let error: JSONValue?
    let cost: Double?
    let providerID: String?
    let modelID: String?
    let variant: String?
    let tokens: OCTokens?
    /// The mode the message ran in — `build`, `plan`, and `compaction` for the assistant message
    /// whose text is a summary rather than an answer. The summary prose is real, but it is the
    /// seam's payload, not a turn the reader needs on its own.
    let mode: String?
    /// The word the server puts on a finished turn — `stop`, `tool-calls`, `length`, `abort`, or
    /// `unknown` when the model's stream ended without saying why. It is the only thing that
    /// separates a turn that chose to say nothing from one whose provider dropped it, so it is
    /// read even though nothing about a normal turn needs it.
    let finish: String?
}

struct OCTokens: Decodable, Sendable {
    let input: Double?
    let output: Double?
    let reasoning: Double?
    let cache: OCCache?
}

struct OCCache: Decodable, Sendable {
    let read: Double?
    let write: Double?
}

struct OCToolState: Decodable, Sendable {
    let status: String
    let input: JSONValue?
    let output: String?
    let title: String?
    let error: String?
}

struct OCPart: Decodable, Sendable {
    let id: String
    let messageID: String
    let sessionID: String?
    let type: String
    let text: String?
    let callID: String?
    let tool: String?
    let state: OCToolState?
    let mime: String?
    let url: String?
    let filename: String?
    /// opencode's compaction marker: `auto` says whether the machine compacted on its own, and
    /// `tail_start_id` appears once the summary's start point has been chosen. The marker carries
    /// no summary — that is written into the assistant message that follows it.
    let auto: Bool?
    let overflow: Bool?
    let tailStartID: String?

    private enum CodingKeys: String, CodingKey {
        case id, messageID, sessionID, type, text, callID, tool, state, mime, url, filename, auto,
            overflow
        case tailStartID = "tail_start_id"
    }
}

struct OCMessageEnvelope: Decodable, Sendable {
    let info: OCMessage
    let parts: [OCPart]
}

struct OCProvidersResponse: Decodable, Sendable {
    let providers: [OCProvider]
    let `default`: [String: String]?
}

struct OCProvider: Decodable, Sendable {
    let id: String
    let name: String?
    let models: [String: OCModel]?
}

struct OCModel: Decodable, Sendable {
    let id: String?
    let name: String?
    let capabilities: OCModelCapabilities?
    let variants: [String: OCModelVariant]?
}

struct OCModelVariant: Decodable, Sendable {}

struct OCModelCapabilities: Decodable, Sendable {
    struct Input: Decodable, Sendable {
        let image: Bool?
        let pdf: Bool?
    }
    let attachment: Bool?
    let input: Input?
}

struct OCFileNode: Decodable, Sendable {
    let name: String
    let path: String
    let type: String?
}

struct OCFileContent: Decodable, Sendable {
    let type: String?
    let content: String
}

struct OCDiff: Decodable, Sendable {
    let file: String?
    let patch: String?
    let additions: Int?
    let deletions: Int?
}

struct OCFindMatch: Decodable, Sendable {
    struct TextWrapper: Decodable, Sendable {
        let text: String?
    }
    let path: TextWrapper?
    let lines: TextWrapper?
    let lineNumber: Int?

    enum CodingKeys: String, CodingKey {
        case path
        case lines
        case lineNumber = "line_number"
    }
}

enum OCPartInput: Encodable, Sendable {
    case text(String)
    case file(mime: String, filename: String?, url: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, mime, filename, url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try container.encode("text", forKey: .type)
            try container.encode(value, forKey: .text)
        case .file(let mime, let filename, let url):
            try container.encode("file", forKey: .type)
            try container.encode(mime, forKey: .mime)
            try container.encodeIfPresent(filename, forKey: .filename)
            try container.encode(url, forKey: .url)
        }
    }
}

struct OCModelInput: Encodable, Sendable {
    let providerID: String
    let modelID: String
}

struct OCSessionCreateRequest: Encodable, Sendable {
    let title: String?
}

struct OCPtyRequest: Encodable, Sendable {
    let command: String
    let args: [String]
    let title: String
}

struct OCPty: Decodable, Sendable {
    let id: String
}

struct OCPtyEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload
}

struct OCPromptRequest: Encodable, Sendable {
    let parts: [OCPartInput]
    let model: OCModelInput?
    let agent: String?
    let variant: String?
}

struct OCCommand: Decodable, Sendable {
    let name: String
    let description: String?
    let agent: String?
    let model: String?
    /// `command`, `mcp`, or `skill`.
    let source: String?
    let subtask: Bool?
    /// Placeholder names the command's template expects, if any.
    let hints: [String]?
}

/// The command route is not the prompt route: `arguments` is required (omitting the key is a 400,
/// not an empty run) and the model is one `providerID/modelID` string rather than the prompt
/// route's object. `variant` carries the reasoning effort under the name opencode gives it.
struct OCCommandRequest: Encodable, Sendable {
    let command: String
    let arguments: String
    let model: String?
    let agent: String?
    let variant: String?
}

struct OCQuestionRequestDTO: Decodable {
    struct Option: Decodable {
        let label: String
        let description: String?
    }

    struct Info: Decodable {
        let question: String
        let header: String?
        let options: [Option]?
        let multiple: Bool?
        let custom: Bool?
    }

    let id: String
    let sessionID: String
    let questions: [Info]
}
