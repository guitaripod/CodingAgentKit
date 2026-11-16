import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a desktop client tells a server about the person in front of it.
///
/// A desk reports every ``interval`` while it runs, and at once when something a phone would act
/// on changes: the screen locked or unlocked, the machine is about to sleep, the app is quitting.
/// A server keeps nothing it was not told and forgets a desk that stops reporting
/// (``DeskPresence/staleAfter``), so a crashed app, a closed lid or a dropped tailnet all read as
/// the person having left, never as them still sitting there.
public struct DeskReport: Sendable, Codable, Equatable {
    /// This desktop installation, stable across launches, so a server holds one entry per desk.
    public var desk: String
    /// What the person calls this computer, for a phone to say where they are.
    public var name: String
    /// Whole seconds since the last keyboard or pointer input anywhere on this desktop, not just
    /// in this app. Nil from a desk that cannot tell, which never counts as anyone being there.
    public var idle: Int?
    /// The screen is locked or the screen saver is up: the person walked away on purpose.
    public var locked: Bool
    /// The app is quitting or the machine is going to sleep, so this is the desk's last word.
    public var leaving: Bool
    /// Conversations the person had in front of them in a focused window since the last report,
    /// by session id. A notice held back while they were here is no longer news once its chat was
    /// on their screen.
    public var looked: [String]
    /// How many seconds before this report each of `looked` was last on screen, so a server can
    /// tell a look from before a notice it held from one after it. Nil from a desk that predates
    /// it, whose looks a server dates to the start of the window they came from.
    public var lookedAgo: [String: Int]?

    /// How often a running desk reports. A server forgets one after ``DeskPresence/staleAfter``,
    /// three of these, so a single dropped report changes nothing.
    public static let interval: TimeInterval = 30

    public init(
        desk: String, name: String, idle: Int?, locked: Bool = false, leaving: Bool = false,
        looked: [String] = [], lookedAgo: [String: Int]? = nil
    ) {
        self.desk = desk
        self.name = name
        self.idle = idle
        self.locked = locked
        self.leaving = leaving
        self.looked = looked
        self.lookedAgo = lookedAgo
    }
}

/// What a server knows about the desks reporting to it, as of its answer.
///
/// Presence is about the person, not the server: every desk reports to every server it holds, so
/// any server that keeps desks can answer for all of them, and a device asking several takes the
/// union of what they say.
public struct DeskPresence: Sendable, Codable, Equatable {
    public struct Desk: Sendable, Codable, Equatable {
        public var desk: String
        public var name: String
        /// Seconds since the last input, as of the server's answer rather than the desk's report.
        public var idle: Int?
        public var locked: Bool
        /// Seconds since the desk last reported.
        public var heard: Int

        public init(desk: String, name: String, idle: Int?, locked: Bool, heard: Int) {
            self.desk = desk
            self.name = name
            self.idle = idle
            self.locked = locked
            self.heard = heard
        }
    }

    public var desks: [Desk]
    /// The last time any desk had each conversation on screen, by session id.
    public var looked: [String: Date]
    /// Set by the waiting route when it answered because nobody is at a desk any more.
    public var away: Bool?

    /// A desk silent for this long has gone: the app quit or crashed, the machine slept, the
    /// network between them dropped.
    public static let staleAfter: TimeInterval = 90

    public init(desks: [Desk] = [], looked: [String: Date] = [:], away: Bool? = nil) {
        self.desks = desks
        self.looked = looked
        self.away = away
    }

    /// The desk the person is at, judged by the asking device's own patience: one that reported
    /// lately, is unlocked, and saw input within `awayAfter`. The most recently used one when
    /// several qualify; nil when none does.
    public func occupied(awayAfter: TimeInterval) -> Desk? {
        desks
            .filter { desk in
                guard !desk.locked, TimeInterval(desk.heard) < Self.staleAfter,
                    let idle = desk.idle
                else { return false }
                return TimeInterval(idle) < awayAfter
            }
            .min { ($0.idle ?? .max) < ($1.idle ?? .max) }
    }

    /// Whether a desk showed this conversation at or after `moment`. A server writes its dates
    /// in whole seconds, so a look in the same second as the moment counts.
    public func looked(at sessionID: String, since moment: Date) -> Bool {
        guard let seen = looked[sessionID] else { return false }
        return seen.timeIntervalSince1970 >= moment.timeIntervalSince1970.rounded(.down)
    }

    /// Several servers' answers as one: every desk once, by its freshest report, and every
    /// conversation by the latest look any of them saw.
    public static func merged(_ answers: [DeskPresence]) -> DeskPresence {
        var desks: [String: Desk] = [:]
        var looked: [String: Date] = [:]
        for answer in answers {
            for desk in answer.desks {
                if let known = desks[desk.desk], known.heard <= desk.heard { continue }
                desks[desk.desk] = desk
            }
            looked.merge(answer.looked) { max($0, $1) }
        }
        return DeskPresence(
            desks: desks.values.sorted { $0.desk < $1.desk }, looked: looked,
            away: answers.contains { $0.away == true } ? true : nil)
    }

    private enum CodingKeys: String, CodingKey {
        case desks, looked, away
    }

    /// Forgiving of what a newer server adds and of a date written with or without fractional
    /// seconds; a look whose date cannot be read is dropped rather than failing the answer.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        desks = try container.decodeIfPresent([Desk].self, forKey: .desks) ?? []
        var looks: [String: Date] = [:]
        if container.contains(.looked),
            let entries = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: .looked)
        {
            for key in entries.allKeys {
                guard let text = try? entries.decode(String.self, forKey: key),
                    let date = TurnWaitDate.parse(text)
                else { continue }
                looks[key.stringValue] = date
            }
        }
        looked = looks
        away = try container.decodeIfPresent(Bool.self, forKey: .away)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(desks, forKey: .desks)
        try container.encode(looked.mapValues(TurnWaitDate.format), forKey: .looked)
        try container.encodeIfPresent(away, forKey: .away)
    }

    /// Reads an answer from the raw body a caller received, very possibly in a background session
    /// of another process, after the blank lines a holding server wrote to keep it open.
    public static func decode(status: Int, body: Data) throws -> DeskPresence {
        guard (200..<300).contains(status) else {
            throw AgentError.http(status: status, body: String(data: body, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(DeskPresence.self, from: body)
        } catch {
            throw AgentError.decoding("desk presence: \(error)")
        }
    }
}

/// A notice a device raised itself while its person was at a desk, handed to a server that holds
/// the device's pushes, so it goes out through APNs once they leave rather than waiting on the
/// device to wake. The words and the fields a tap reads are the device's own.
public struct DeskHeldNotice: Sendable, Codable, Equatable {
    /// The device's APNs token, as registered with this server.
    public var token: String
    /// The notification's identifier, which collapses a later notice for the same thing.
    public var identifier: String
    public var title: String
    public var body: String
    public var sessionID: String?
    public var threadID: String?
    public var category: String?
    /// The fields the notification carries for a tap, as one JSON object.
    public var userInfo: String?

    public init(
        token: String, identifier: String, title: String, body: String, sessionID: String? = nil,
        threadID: String? = nil, category: String? = nil, userInfo: String? = nil
    ) {
        self.token = token
        self.identifier = identifier
        self.title = title
        self.body = body
        self.sessionID = sessionID
        self.threadID = threadID
        self.category = category
        self.userInfo = userInfo
    }
}

extension CodingAgentBackend {
    public func holdNotice(_ notice: DeskHeldNotice) async throws -> Bool { false }

    public func reportDesk(_ report: DeskReport) async throws -> Bool { false }

    public func deskPresence() async throws -> DeskPresence? { nil }

    public func deskAwayRequest(awayAfter: TimeInterval) async throws -> TurnWaitRequest? { nil }
}
