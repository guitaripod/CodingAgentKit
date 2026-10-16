import Foundation

/// The wire any daemon speaks to say what its machine can do and to fix what it cannot. It grows by
/// adding fields and cases, and an older peer reads a newer one without breaking: an unknown state
/// decodes to the most cautious known one.
public enum SetupWire {
    public static let version = 1
    public static let setupPath = "/setup"
    public static let fixPath = "/setup/fix"
    public static let jobsPath = "/setup/jobs"
}

/// The capability ids the apps know by name. A daemon may report others, which a client shows by the
/// words the report carries.
public enum SetupCapability {
    public static let voice = "voice"
    public static let media = "media"
    public static let agent = "agent"
    public static let delegate = "delegate"
    public static let preview = "preview"
}

public enum SetupState: String, Codable, Sendable, Hashable {
    case ok, todo, working, blocked, unavailable

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SetupState(rawValue: raw) ?? .blocked
    }

    public var isSettled: Bool { self != .working }
}

/// What makes a check pass. A `job` is something the daemon does itself; a `command` is the one thing
/// that needs the person's own privileges, handed over to copy with the reason it is needed.
public struct SetupFix: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case job, command

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .command
        }
    }

    public var id: String
    public var kind: Kind
    public var command: String?
    public var reason: String?
    public var bytes: Int64?
    public var minutes: Int?

    public init(
        id: String, kind: Kind = .job, command: String? = nil, reason: String? = nil,
        bytes: Int64? = nil, minutes: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.command = command
        self.reason = reason
        self.bytes = bytes
        self.minutes = minutes
    }
}

/// One thing the machine proves. `facts` are names and numbers, never sentences: the app writes the
/// words in the person's language from the id and the facts, and shows `detail` only for an id it has
/// never seen.
public struct SetupCheck: Codable, Sendable, Hashable {
    public var id: String
    public var state: SetupState
    public var facts: [String: String]
    public var detail: String?
    public var fix: SetupFix?

    public init(
        id: String, state: SetupState, facts: [String: String] = [:], detail: String? = nil,
        fix: SetupFix? = nil
    ) {
        self.id = id
        self.state = state
        self.facts = facts
        self.detail = detail
        self.fix = fix
    }
}

public struct SetupReport: Codable, Sendable, Hashable {
    public var capability: String
    public var available: Bool
    public var ready: Bool
    public var checks: [SetupCheck]
    public var job: SetupJob?

    public init(
        capability: String, available: Bool = true, ready: Bool, checks: [SetupCheck],
        job: SetupJob? = nil
    ) {
        self.capability = capability
        self.available = available
        self.ready = ready
        self.checks = checks
        self.job = job
    }

    public var firstOpen: SetupCheck? { checks.first { $0.state != .ok } }
}

public enum SetupJobState: String, Codable, Sendable, Hashable {
    case queued, running, succeeded, failed, cancelled

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SetupJobState(rawValue: raw) ?? .running
    }

    public var isSettled: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

public struct SetupJob: Codable, Sendable, Hashable {
    public var id: String
    public var fix: String
    public var state: SetupJobState
    public var step: String?
    public var fraction: Double?
    public var bytesDone: Int64?
    public var bytesTotal: Int64?
    public var failure: String?
    public var facts: [String: String]
    public var startedAt: Double

    public init(
        id: String, fix: String, state: SetupJobState, step: String? = nil, fraction: Double? = nil,
        bytesDone: Int64? = nil, bytesTotal: Int64? = nil, failure: String? = nil,
        facts: [String: String] = [:], startedAt: Double = 0
    ) {
        self.id = id
        self.fix = fix
        self.state = state
        self.step = step
        self.fraction = fraction
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.failure = failure
        self.facts = facts
        self.startedAt = startedAt
    }
}

public struct SetupFixRequest: Codable, Sendable, Hashable {
    public var fix: String

    public init(fix: String) { self.fix = fix }
}

public enum SetupCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
