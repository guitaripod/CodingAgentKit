import Foundation

public struct AgentSession: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let agentType: AgentType
    public var title: String
    public var parentID: String?
    public var directory: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// The session's transcript is being written to right now — an agent is
    /// actively working in it (on the server machine or via this client).
    public var isActive: Bool?

    public init(
        id: String,
        agentType: AgentType,
        title: String,
        parentID: String? = nil,
        directory: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        isActive: Bool? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.title = title
        self.parentID = parentID
        self.directory = directory
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isActive = isActive
    }
}
