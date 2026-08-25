public enum AgentType: String, Sendable, Hashable, Codable, CaseIterable {
    case openCode
    case claudeCode
    case omp

    public var displayName: String {
        switch self {
        case .openCode: return "opencode"
        case .claudeCode: return "Claude Code"
        case .omp: return "Oh My Pi"
        }
    }
}
