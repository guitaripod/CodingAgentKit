import Foundation

/// The constants both ends of a call agree on. The wire is versioned by `version` and grows by
/// adding fields and cases, never by renaming.
public enum VoiceWire {
    public static let version = 1
    public static let port = 4102
    public static let callPath = "/call"
    public static let healthPath = "/health"
    public static let sampleRate = 24_000
    public static let preferredChunkBytes = 3_840
    public static let maxChunkBytes = 16_384
    public static let digestLimit = 300
    public static let dispatchLimit = 4_000
}

public enum VoiceClientKind: String, Codable, Sendable, Hashable {
    case ios, mac, linux
}

/// What the call is doing from the person's side of the glass. `hearing` is the person speaking;
/// the agent working is not a phase, the client knows that from its own conversation.
public enum VoicePhase: String, Codable, Sendable, Hashable {
    case connecting, listening, hearing, speaking, degraded
}

public enum VoiceDegradedReason: String, Codable, Sendable, Hashable {
    case runaway, loop, engineError, engineDown, overload
}

public enum VoiceEngineState: String, Codable, Sendable, Hashable {
    case ready, loading, down, busy, stopped, needsSetup

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VoiceEngineState(rawValue: raw) ?? .down
    }
}

public struct VoiceHealth: Codable, Sendable, Hashable {
    public var gateway: String
    public var protocolVersion: Int
    public var engine: VoiceEngineState
    public var model: String?
    public var calls: Int
    public var detail: String?

    public init(
        gateway: String, protocolVersion: Int = VoiceWire.version, engine: VoiceEngineState,
        model: String? = nil, calls: Int = 0, detail: String? = nil
    ) {
        self.gateway = gateway
        self.protocolVersion = protocolVersion
        self.engine = engine
        self.model = model
        self.calls = calls
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case gateway, engine, model, calls, detail
        case protocolVersion = "protocol"
    }
}

public enum VoiceClientMessage: Sendable, Hashable {
    case hello(Hello)
    case agent(AgentState)
    case sent(id: String)
    case refused(id: String, reason: String)
    case bye
    case unknown(String)

    public struct Hello: Codable, Sendable, Hashable {
        public var v: Int
        public var client: VoiceClientKind
        public var app: String
        public var title: String?

        public init(v: Int = VoiceWire.version, client: VoiceClientKind, app: String, title: String? = nil) {
            self.v = v
            self.client = client
            self.app = app
            self.title = title
        }
    }

    public struct AgentState: Codable, Sendable, Hashable {
        public var busy: Bool
        public var digest: String
        public var turn: Int

        public init(busy: Bool, digest: String, turn: Int) {
            self.busy = busy
            self.digest = digest
            self.turn = turn
        }
    }
}

public enum VoiceServerMessage: Sendable, Hashable {
    case ready(Ready)
    case phase(VoicePhase, at: Double)
    case user(id: String, text: String, final: Bool)
    case say(text: String, final: Bool)
    case dispatch(id: String, text: String)
    case stop
    case degraded(VoiceDegradedReason, recovering: Bool)
    case recycled
    case engine(VoiceEngineState, progress: Double?)
    case error(code: String, message: String)
    case unknown(String)

    public struct Ready: Codable, Sendable, Hashable {
        public var v: Int
        public var gateway: String
        public var model: String

        public init(v: Int = VoiceWire.version, gateway: String, model: String) {
            self.v = v
            self.gateway = gateway
            self.model = model
        }
    }
}

extension VoiceClientMessage: Codable {
    private enum Key: String, CodingKey {
        case t, id, reason, v, client, app, title, busy, digest, turn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let tag = try c.decode(String.self, forKey: .t)
        switch tag {
        case "hello":
            self = .hello(try Hello(from: decoder))
        case "agent":
            self = .agent(try AgentState(from: decoder))
        case "sent":
            self = .sent(id: try c.decode(String.self, forKey: .id))
        case "refused":
            self = .refused(
                id: try c.decode(String.self, forKey: .id),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "bye":
            self = .bye
        default:
            self = .unknown(tag)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .hello(let hello):
            try c.encode("hello", forKey: .t)
            try c.encode(hello.v, forKey: .v)
            try c.encode(hello.client, forKey: .client)
            try c.encode(hello.app, forKey: .app)
            try c.encodeIfPresent(hello.title, forKey: .title)
        case .agent(let state):
            try c.encode("agent", forKey: .t)
            try c.encode(state.busy, forKey: .busy)
            try c.encode(state.digest, forKey: .digest)
            try c.encode(state.turn, forKey: .turn)
        case .sent(let id):
            try c.encode("sent", forKey: .t)
            try c.encode(id, forKey: .id)
        case .refused(let id, let reason):
            try c.encode("refused", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(reason, forKey: .reason)
        case .bye:
            try c.encode("bye", forKey: .t)
        case .unknown(let tag):
            try c.encode(tag, forKey: .t)
        }
    }
}

extension VoiceServerMessage: Codable {
    private enum Key: String, CodingKey {
        case t, v, gateway, model, phase, at, id, text, final, reason, recovering, code, message, state, progress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let tag = try c.decode(String.self, forKey: .t)
        switch tag {
        case "ready":
            self = .ready(try Ready(from: decoder))
        case "phase":
            self = .phase(
                try c.decode(VoicePhase.self, forKey: .phase),
                at: try c.decodeIfPresent(Double.self, forKey: .at) ?? 0)
        case "user":
            self = .user(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                final: try c.decodeIfPresent(Bool.self, forKey: .final) ?? false)
        case "say":
            self = .say(
                text: try c.decode(String.self, forKey: .text),
                final: try c.decodeIfPresent(Bool.self, forKey: .final) ?? false)
        case "dispatch":
            self = .dispatch(
                id: try c.decode(String.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "stop":
            self = .stop
        case "degraded":
            self = .degraded(
                try c.decode(VoiceDegradedReason.self, forKey: .reason),
                recovering: try c.decodeIfPresent(Bool.self, forKey: .recovering) ?? false)
        case "recycled":
            self = .recycled
        case "engine":
            self = .engine(
                try c.decode(VoiceEngineState.self, forKey: .state),
                progress: try c.decodeIfPresent(Double.self, forKey: .progress))
        case "error":
            self = .error(
                code: try c.decode(String.self, forKey: .code),
                message: try c.decodeIfPresent(String.self, forKey: .message) ?? "")
        default:
            self = .unknown(tag)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .ready(let ready):
            try c.encode("ready", forKey: .t)
            try c.encode(ready.v, forKey: .v)
            try c.encode(ready.gateway, forKey: .gateway)
            try c.encode(ready.model, forKey: .model)
        case .phase(let phase, let at):
            try c.encode("phase", forKey: .t)
            try c.encode(phase, forKey: .phase)
            try c.encode(at, forKey: .at)
        case .user(let id, let text, let final):
            try c.encode("user", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encode(final, forKey: .final)
        case .say(let text, let final):
            try c.encode("say", forKey: .t)
            try c.encode(text, forKey: .text)
            try c.encode(final, forKey: .final)
        case .dispatch(let id, let text):
            try c.encode("dispatch", forKey: .t)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .stop:
            try c.encode("stop", forKey: .t)
        case .degraded(let reason, let recovering):
            try c.encode("degraded", forKey: .t)
            try c.encode(reason, forKey: .reason)
            try c.encode(recovering, forKey: .recovering)
        case .recycled:
            try c.encode("recycled", forKey: .t)
        case .engine(let state, let progress):
            try c.encode("engine", forKey: .t)
            try c.encode(state, forKey: .state)
            try c.encodeIfPresent(progress, forKey: .progress)
        case .error(let code, let message):
            try c.encode("error", forKey: .t)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        case .unknown(let tag):
            try c.encode(tag, forKey: .t)
        }
    }
}

/// One text frame in and out, so no end writes its own JSON.
public enum VoiceCodec {
    public static func encode(_ message: VoiceClientMessage) throws -> String { try string(message) }
    public static func encode(_ message: VoiceServerMessage) throws -> String { try string(message) }

    public static func decodeClient(_ text: String) throws -> VoiceClientMessage {
        try JSONDecoder().decode(VoiceClientMessage.self, from: Data(text.utf8))
    }

    public static func decodeServer(_ text: String) throws -> VoiceServerMessage {
        try JSONDecoder().decode(VoiceServerMessage.self, from: Data(text.utf8))
    }

    private static func string<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// The model's system prompt and tool results must be ASCII. Accents are folded to their letters,
/// anything else is dropped to a space, runs of space collapse, and a long text is cut at a word.
public enum VoiceText {
    public static func ascii(_ text: String, limit: Int = .max) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = String.UnicodeScalarView()
        var lastSpace = true
        for scalar in folded.unicodeScalars {
            let plain = scalar.isASCII && (scalar.value >= 0x20 && scalar.value < 0x7F)
            let mapped: Unicode.Scalar = plain ? scalar : " "
            if mapped == " " {
                if lastSpace { continue }
                lastSpace = true
            } else {
                lastSpace = false
            }
            out.append(mapped)
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return clip(result, to: limit)
    }

    private static func clip(_ text: String, to limit: Int) -> String {
        guard limit >= 0, text.count > limit else { return text }
        let head = text.prefix(limit)
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            return String(head[..<space])
        }
        return String(head)
    }
}
