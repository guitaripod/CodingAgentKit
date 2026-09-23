import AgentCore
import Foundation

/// opencode 2's wire, as the server encodes it. Every route answers under `/api`, wraps its
/// payload in `data` (with the resolved `location` beside it where the route is scoped), pages
/// with an opaque cursor, and stamps every clock as epoch milliseconds. Fields are optional
/// wherever the schema allows it and a little beyond, because a record the server is still
/// writing has not decided all of them yet.
struct OC2Envelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload
}

struct OC2Page<Item: Decodable & Sendable>: Decodable, Sendable {
    let data: [Item]
    let cursor: OC2Cursor?
}

struct OC2Cursor: Decodable, Sendable {
    let previous: String?
    let next: String?
}

struct OC2ServerInfo: Decodable, Sendable {
    let version: String
    let pid: Int?
    let urls: [String]?
}

struct OC2Location: Decodable, Sendable {
    let directory: String?
}

/// The model a session or message ran with. `id` is the model's own name inside its provider;
/// `variant` is the effort level opencode names per model.
struct OC2ModelRef: Codable, Sendable {
    let id: String?
    let providerID: String?
    let variant: String?
}

struct OC2ModelRefInput: Encodable, Sendable {
    let id: String
    let providerID: String
    let variant: String?
}

struct OC2Tokens: Decodable, Sendable {
    let input: Double?
    let output: Double?
    let reasoning: Double?
    let cache: OC2Cache?
}

struct OC2Cache: Decodable, Sendable {
    let read: Double?
    let write: Double?
}

struct OC2SessionTime: Decodable, Sendable {
    let created: Double?
    let updated: Double?
    let idle: Double?
    let archived: Double?
}

/// The session record. It carries the conversation's running cost and tokens, which is the only
/// ledger opencode serves cheaply, and its location, which is the directory the turn runs in.
struct OC2Session: Decodable, Sendable {
    let id: String
    let parentID: String?
    let projectID: String?
    let agent: String?
    let model: OC2ModelRef?
    let cost: Double?
    let tokens: OC2Tokens?
    let outcome: String?
    let time: OC2SessionTime?
    let title: String?
    let location: OC2Location?
}

/// What a session is doing right now, from the process-wide `/api/session/active` map. Only
/// sessions with something in flight are listed, so an absent id is a session with nothing open.
struct OC2SessionStatus: Decodable, Sendable {
    let type: String
}

struct OC2Error: Decodable, Sendable {
    let type: String?
    let message: String?
    let status: Int?
}

struct OC2MessageTime: Decodable, Sendable {
    let created: Double?
    let streamed: Double?
    let completed: Double?
}

/// One transcript record. opencode 2 stores the transcript as a tagged union — user, assistant,
/// compaction, shell, idle and a handful of bookkeeping kinds — and this reads all of them as one
/// shape with the fields each kind may carry, so the mapping can switch on `type` without a
/// decoder per kind.
struct OC2Message: Decodable, Sendable {
    let id: String
    let type: String
    let time: OC2MessageTime?
    let text: String?
    let description: String?
    let files: [OC2PromptFile]?
    let agent: String?
    let model: OC2ModelRef?
    let content: [OC2Content]?
    let finish: String?
    let rawFinish: String?
    let cost: Double?
    let tokens: OC2Tokens?
    let error: OC2Error?
    let status: String?
    let reason: String?
    let summary: String?
    let shellID: String?
    let command: String?
    let exit: Int?
    let output: OC2ShellOutput?
    let outcome: String?
}

struct OC2ShellOutput: Decodable, Sendable {
    let output: String?
    let truncated: Bool?
}

/// One block of an assistant message: prose, a thought, or a tool call with its state. `state`
/// means two things on the wire — a tool call's own state, and the provider's opaque record
/// on prose and thoughts — so it is read only where it is the tool's.
struct OC2Content: Decodable, Sendable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let executed: Bool?
    let state: OC2ToolState?
    let time: OC2ContentTime?

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, executed, state, time
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        executed = try container.decodeIfPresent(Bool.self, forKey: .executed)
        time = try container.decodeIfPresent(OC2ContentTime.self, forKey: .time)
        state = type == "tool" ? try container.decodeIfPresent(OC2ToolState.self, forKey: .state) : nil
    }
}

struct OC2ContentTime: Decodable, Sendable {
    let created: Double?
    let ran: Double?
    let completed: Double?
}

/// A tool call's state. `input` is the raw text while the model is still writing the call and
/// the parsed object from the moment it runs, so it is read as either.
struct OC2ToolState: Decodable, Sendable {
    let status: String
    let input: JSONValue?
    let content: [OC2ToolContent]?
    let error: OC2Error?
    let metadata: JSONValue?
}

struct OC2ToolContent: Decodable, Sendable {
    let type: String
    let text: String?
    let uri: String?
    let mime: String?
    let name: String?
}

/// A file handed to a prompt: opencode reads the uri itself, so a name is all it takes beside it.
struct OC2FileAttachment: Encodable, Sendable {
    let uri: String
    let name: String?
}

/// A file as a stored or queued prompt holds it: the bytes inline, whatever uri they came from
/// recorded as their source.
struct OC2PromptFile: Decodable, Sendable {
    let data: String?
    let mime: String?
    let name: String?
    let source: OC2PromptFileSource?
}

struct OC2PromptFileSource: Decodable, Sendable {
    let type: String
    let uri: String?
}

struct OC2PromptRequest: Encodable, Sendable {
    let text: String
    let files: [OC2FileAttachment]?
}

struct OC2CommandRequest: Encodable, Sendable {
    let name: String
    let text: String
}

struct OC2SessionCreateRequest: Encodable, Sendable {
    struct Location: Encodable, Sendable {
        let directory: String
    }
    let location: Location?
}

struct OC2PermissionSource: Decodable, Sendable {
    let type: String?
    let messageID: String?
    let id: String?
}

struct OC2Permission: Decodable, Sendable {
    let id: String
    let sessionID: String
    let action: String?
    let resources: [String]?
    let message: String?
    let source: OC2PermissionSource?
}

struct OC2Form: Decodable, Sendable {
    let id: String
    let sessionID: String
    let title: String?
    let fields: [OC2FormField]
}

struct OC2FormField: Decodable, Sendable {
    let key: String
    let type: String
    let title: String?
    let description: String?
    let required: Bool?
    let options: [OC2FormOption]?
    let custom: Bool?
    let url: String?
}

struct OC2FormOption: Decodable, Sendable {
    let value: String
    let label: String
    let description: String?
}

struct OC2Model: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable {
        let tools: Bool?
        let input: [String]?
    }
    struct Variant: Decodable, Sendable {
        let id: String
    }
    struct Limit: Decodable, Sendable {
        let context: Double?
        let output: Double?
    }
    let id: String
    let modelID: String?
    let providerID: String
    let name: String?
    let capabilities: Capabilities?
    let variants: [Variant]?
    let limit: Limit?
    let enabled: Bool?
    let status: String?
}

struct OC2Provider: Decodable, Sendable {
    let id: String
    let name: String?
    let activation: String?
}

struct OC2Agent: Decodable, Sendable {
    let id: String
    let name: String?
    let mode: String?
    let hidden: Bool?
}

struct OC2Command: Decodable, Sendable {
    let name: String
    let description: String?
}

struct OC2FSEntry: Decodable, Sendable {
    let path: String
    let type: String?
}

struct OC2Diff: Decodable, Sendable {
    let file: String?
    let patch: String?
    let additions: Int?
    let deletions: Int?
}

struct OC2Pty: Decodable, Sendable {
    let id: String
    let status: String?
}

struct OC2PtyRequest: Encodable, Sendable {
    let command: String
    let args: [String]
}

struct OC2Project: Decodable, Sendable {
    struct Time: Decodable, Sendable {
        let created: Double?
        let updated: Double?
    }
    let id: String
    let canonical: String?
    let name: String?
    let time: Time?
}

/// One frame off `/api/event`: the event's own name, when it happened, the workspace it came
/// from where it has one, and a payload whose shape the name decides.
struct OC2Event: Decodable, Sendable {
    let id: String?
    let type: String
    let created: Double?
    let location: OC2Location?
    let data: JSONValue?
}
