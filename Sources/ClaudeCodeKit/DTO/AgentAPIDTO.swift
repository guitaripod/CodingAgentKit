struct AAMessage: Decodable, Sendable {
    let id: Int
    let content: String
    let role: String
    let time: String?
}

struct AAMessagesResponse: Decodable, Sendable {
    let messages: [AAMessage]
}

struct AAStatus: Decodable, Sendable {
    let agentType: String?
    let status: String
    let transport: String?

    enum CodingKeys: String, CodingKey {
        case agentType = "agent_type"
        case status
        case transport
    }
}

struct AAMessageUpdate: Decodable, Sendable {
    let id: Int
    let message: String
    let role: String
    let time: String?
}

struct AAStatusChange: Decodable, Sendable {
    let agentType: String?
    let status: String

    enum CodingKeys: String, CodingKey {
        case agentType = "agent_type"
        case status
    }
}

struct AAError: Decodable, Sendable {
    let level: String?
    let message: String
    let time: String?
}

struct AASendMessage: Encodable, Sendable {
    let content: String
    let type: String
}
