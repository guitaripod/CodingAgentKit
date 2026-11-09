import Foundation

/// A stretch of a conversation under one title, as the server that keeps them reports it. A
/// chapter begins where the server judged that the topic had moved on; a new name for the same
/// stretch renames the chapter rather than starting another. Only a server that re-titles a
/// conversation as it goes (claude-bridge 1.22 and later) keeps them.
public struct ConversationChapter: Sendable, Hashable, Codable {
    /// Who gave the chapter its current name. `kept` is the name a conversation already wore when
    /// its server began keeping chapters, which may describe its later stretch rather than its
    /// first. A word this client does not know reads as `model`, the server's ordinary namer.
    public enum Namer: String, Sendable, Hashable, Codable {
        case prompt, model, person, agent, schedule, fork, kept

        public init(from decoder: any Decoder) throws {
            let word = try decoder.singleValueContainer().decode(String.self)
            self = Namer(rawValue: word) ?? .model
        }
    }

    public var title: String
    /// The person's message the chapter begins at, counted from one.
    public var turn: Int
    /// That message's id, when the server named it.
    public var messageID: String?
    public var startedAt: Date
    /// What the chapter came to, in one sentence, once the next one has begun.
    public var gist: String?
    public var namedBy: Namer

    public init(
        title: String, turn: Int, messageID: String? = nil, startedAt: Date, gist: String? = nil,
        namedBy: Namer = .model
    ) {
        self.title = title
        self.turn = turn
        self.messageID = messageID
        self.startedAt = startedAt
        self.gist = gist
        self.namedBy = namedBy
    }

    private enum CodingKeys: String, CodingKey {
        case title, turn, messageID, startedAt, gist, namedBy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        turn = max(1, try container.decode(Int.self, forKey: .turn))
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        gist = try container.decodeIfPresent(String.self, forKey: .gist)
        namedBy = try container.decodeIfPresent(Namer.self, forKey: .namedBy) ?? .model
    }
}
