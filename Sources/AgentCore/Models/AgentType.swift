public enum AgentType: String, Sendable, Hashable, Codable, CaseIterable {
    case openCode
    case claudeCode

    public var displayName: String {
        switch self {
        case .openCode: return "opencode"
        case .claudeCode: return "Claude Code"
        }
    }
}
