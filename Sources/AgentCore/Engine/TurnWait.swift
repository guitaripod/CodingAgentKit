import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A request that is answered only when a session's turn ends or needs the person — never while
/// it is merely still running.
///
/// It is safe to hand to a process that is not this one: the URL is absolute, the server's own
/// `RequestBuilder` has already baked in `Authorization`, and it carries no side effect, so an app
/// that hands it to a background `URLSession` it does not itself drive can let that session retry
/// it, duplicate it, or hold two of it at once with nothing to show for the difference.
public struct TurnWaitRequest: Sendable {
    public var request: URLRequest
    /// A background `URLSession` accepts only download and `upload(fromFile:)` tasks — the
    /// convenience send/receive APIs throw on it, and a plain data task is refused outright. A GET
    /// wait rides a download task; a POST wait (opencode) must upload from a file, and one holding
    /// no body at all is still a file, just an empty one.
    public var uploadsEmptyBody: Bool

    public init(request: URLRequest, uploadsEmptyBody: Bool) {
        self.request = request
        self.uploadsEmptyBody = uploadsEmptyBody
    }
}

/// Whether, and why not, a session can be waited on right now.
public enum TurnWaitSupport: Sendable, Equatable {
    case supported
    /// The route this server generation would carry the capability on is missing — a fact about
    /// how old this particular server is, never about the session or the generation it speaks.
    case serverTooOld
    /// This backend, or the generation it currently speaks, has no notion of waiting at all — an
    /// older opencode has no wait-without-sending route to be too old *for*.
    case unavailable(Reason)

    /// Why a backend can never be waited on, independent of that server's own age. Words for the
    /// person live in TailscodeCore, which cannot see this Kit's newer types; this stays a closed
    /// vocabulary so Core can still say something true about a reason it was built before.
    public enum Reason: Sendable, Equatable {
        /// opencode 1.x carries no wait-without-sending route at all, in any version — the 2.x
        /// line has one and 1.x never will, because it is a different generation of the API.
        case generation
        /// The default for a backend with no server identity to wait on at all.
        case none
    }
}

/// What the server answered a wait with: whether the turn is over, and — when it is — how it went.
///
/// Decoding is deliberately forgiving of everything a newer server might add or a client might
/// have missed: a leading blank line the heartbeat wrote before the real object, an `ending` this
/// build predates, and any field neither side has agreed on yet. Only a body that fails to name a
/// `state` this build understands is treated as a decode failure — everything else about the wire
/// contract is additive, never breaking.
public struct TurnWaitResult: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        case ended
        case needsYou
        case running
    }

    /// TailscodeCore's `LiveActivityDetail` raw values, reused rather than renamed — this is a wire
    /// contract shared with the bridges, and a case may only ever be added to it.
    public enum Ending: String, Sendable, Codable {
        case finished
        case answerless
        case failed
        case interrupted
        case cancelled
        case question
        case approval
        case lost
    }

    public var state: State
    public var waited: Bool
    public var ending: Ending?
    public var title: String?
    public var toolCount: Int?
    /// Background tasks the CLI still carries after the turn — claude-bridge only.
    public var background: Int?
    public var duration: TimeInterval?
    public var lastMessageID: String?
    public var endedAt: Date?

    public init(
        state: State, waited: Bool, ending: Ending? = nil, title: String? = nil,
        toolCount: Int? = nil, background: Int? = nil, duration: TimeInterval? = nil,
        lastMessageID: String? = nil, endedAt: Date? = nil
    ) {
        self.state = state
        self.waited = waited
        self.ending = ending
        self.title = title
        self.toolCount = toolCount
        self.background = background
        self.duration = duration
        self.lastMessageID = lastMessageID
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case state, waited, ending, title, toolCount, background, duration, lastMessageID, endedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawState = try container.decode(String.self, forKey: .state)
        guard let state = State(rawValue: rawState) else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container, debugDescription: "Unknown wait state \(rawState)")
        }
        self.state = state
        self.waited = try container.decodeIfPresent(Bool.self, forKey: .waited) ?? false
        self.ending = try container.decodeIfPresent(String.self, forKey: .ending)
            .flatMap(Ending.init(rawValue:))
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.toolCount = try container.decodeIfPresent(Int.self, forKey: .toolCount)
        self.background = try container.decodeIfPresent(Int.self, forKey: .background)
        self.duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        self.lastMessageID = try container.decodeIfPresent(String.self, forKey: .lastMessageID)
        self.endedAt = try container.decodeIfPresent(String.self, forKey: .endedAt)
            .flatMap(TurnWaitDate.parse)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state.rawValue, forKey: .state)
        try container.encode(waited, forKey: .waited)
        try container.encodeIfPresent(ending?.rawValue, forKey: .ending)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(toolCount, forKey: .toolCount)
        try container.encodeIfPresent(background, forKey: .background)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(lastMessageID, forKey: .lastMessageID)
        if let endedAt {
            try container.encode(TurnWaitDate.format(endedAt), forKey: .endedAt)
        }
    }
}

/// A lenient ISO-8601 reader for the one field this contract stamps with a real timestamp — the
/// bridges format with fractional seconds, but a server that does not is still a server this
/// build must read rather than reject.
enum TurnWaitDate {
    static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension CodingAgentBackend {
    /// A self-contained request for this session's turn to end, or `nil` when this backend has
    /// none to offer — an unsupported generation, a server too old, or a backend with no server to
    /// ask at all. Callers check ``turnWaitSupport()`` first to tell those apart before arming
    /// anything on the strength of a `nil`.
    public func turnWaitRequest(for sessionID: String) async throws -> TurnWaitRequest? { nil }

    public func turnWaitSupport() async -> TurnWaitSupport { .unavailable(.none) }

    /// Reads what a wait answered with. The default matches a backend that never hands out a
    /// request in the first place: nothing should ever call this without one.
    public func turnWaitResult(
        status: Int, headers: [String: String], body: Data, sessionID: String
    ) async throws -> TurnWaitResult {
        throw AgentError.unsupported("turn wait")
    }
}
