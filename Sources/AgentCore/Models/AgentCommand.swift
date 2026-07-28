import Foundation

/// A slash command the *server* resolves, as opposed to a client-side app action. Built-ins come
/// from the agent itself; the rest are files on the server (a user's `~/.claude/commands`, a
/// project's `.claude/commands`, an installed plugin, an opencode MCP prompt or skill) and can only
/// be discovered, never hardcoded into a client.
public struct AgentCommand: Sendable, Hashable, Codable, Identifiable {
    public enum Source: String, Sendable, Hashable, Codable {
        case builtin
        case user
        case project
        case plugin
        case mcp
        case skill
        /// A custom command whose origin the server didn't classify.
        case custom
    }

    /// The command word without its leading slash, including any `namespace:` prefix.
    public var name: String
    public var details: String
    /// The server's hint for what follows the command (`<condition> | clear`), when it takes
    /// arguments at all.
    public var argumentHint: String?
    public var source: Source
    /// The plugin, project, or server that contributed a non-builtin command.
    public var scope: String?

    public var id: String { name }
    public var takesArguments: Bool { !(argumentHint?.isEmpty ?? true) }

    /// The command as a user would type it, which for a CLI-backed agent is also exactly what gets
    /// sent as the prompt.
    public func invocation(arguments: String?) -> String {
        let trimmed = arguments?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "/\(name)" : "/\(name) \(trimmed)"
    }

    public init(
        name: String, details: String, argumentHint: String? = nil, source: Source,
        scope: String? = nil
    ) {
        self.name = name
        self.details = details
        self.argumentHint = argumentHint
        self.source = source
        self.scope = scope
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case details = "description"
        case argumentHint
        case source
        case scope
    }

    /// An unrecognised `source` decodes to ``Source/custom`` rather than failing the whole
    /// catalog — a newer server may classify commands in ways this client predates.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        details = (try? container.decode(String.self, forKey: .details)) ?? ""
        argumentHint = try container.decodeIfPresent(String.self, forKey: .argumentHint)
        source =
            (try? container.decode(String.self, forKey: .source)).flatMap(Source.init(rawValue:))
            ?? .custom
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
    }
}

/// A standing objective the agent keeps working toward, checked before it is allowed to stop
/// (Claude Code's `/goal`). Survives the server respawning the agent process, so it outlives any
/// single turn — the one piece of agent state a phone can set and then walk away from.
public struct SessionGoal: Sendable, Hashable, Codable {
    public var condition: String
    public var isMet: Bool
    public var didFail: Bool
    /// Why the goal was judged met, when the server records it.
    public var reason: String?
    /// How many extra turns the goal drove after the prompt that set it.
    public var iterations: Int?
    public var duration: TimeInterval?
    public var tokens: Int?
    public var updatedAt: Date?

    /// Whether the agent is still pursuing this goal. Mirrors the CLI's own restore rule: a met or
    /// failed record means nothing is being pursued any more.
    public var isActive: Bool { !isMet && !didFail }

    public init(
        condition: String, isMet: Bool, didFail: Bool = false, reason: String? = nil,
        iterations: Int? = nil, duration: TimeInterval? = nil, tokens: Int? = nil,
        updatedAt: Date? = nil
    ) {
        self.condition = condition
        self.isMet = isMet
        self.didFail = didFail
        self.reason = reason
        self.iterations = iterations
        self.duration = duration
        self.tokens = tokens
        self.updatedAt = updatedAt
    }
}
