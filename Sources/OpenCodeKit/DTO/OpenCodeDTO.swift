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

struct OCSession: Decodable, Sendable {
    let id: String
    let title: String?
    let parentID: String?
    let directory: String?
    let time: OCTime?
}

struct OCMessage: Decodable, Sendable {
    let id: String
    let sessionID: String
    let role: String
    let time: OCTime?
    let error: JSONValue?
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

struct OCTextPartInput: Encodable, Sendable {
    let type = "text"
    let text: String
}

struct OCModelInput: Encodable, Sendable {
    let providerID: String
    let modelID: String
}

struct OCPromptRequest: Encodable, Sendable {
    let parts: [OCTextPartInput]
    let model: OCModelInput?
    let agent: String?
}
