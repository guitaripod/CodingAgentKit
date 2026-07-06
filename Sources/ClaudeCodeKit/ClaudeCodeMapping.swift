import AgentCore
import Foundation

enum ClaudeCodeMapping {
    static let contentPartID = "content"

    static func date(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        return Date()
    }

    static func role(_ raw: String) -> MessageRole {
        switch raw {
        case "agent": return .assistant
        case "user": return .user
        default: return .system
        }
    }

    static func status(_ raw: String) -> BackendStatus {
        switch raw {
        case "running": return .running
        case "stable": return .stable
        case "idle": return .idle
        default: return .unknown
        }
    }

    static func chatMessage(id: Int, content: String, role rawRole: String, time: String?)
        -> ChatMessage
    {
        ChatMessage(
            id: String(id),
            role: role(rawRole),
            agentType: .claudeCode,
            parts: [MessagePart(id: contentPartID, kind: .text(content))],
            createdAt: date(time),
            completedAt: nil,
            isStreaming: false,
            error: nil
        )
    }

    static func message(_ message: AAMessage) -> ChatMessage {
        chatMessage(
            id: message.id, content: message.content, role: message.role, time: message.time)
    }

    static func update(_ update: AAMessageUpdate) -> ChatMessage {
        chatMessage(id: update.id, content: update.message, role: update.role, time: update.time)
    }
}

public struct ClaudeAgentStatus: Sendable, Hashable {
    public let agentType: String?
    public let status: BackendStatus
    public let transport: String?

    public init(agentType: String?, status: BackendStatus, transport: String?) {
        self.agentType = agentType
        self.status = status
        self.transport = transport
    }
}
