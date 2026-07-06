import AgentCore
import Foundation

enum OpenCodeMapping {
    static func date(_ milliseconds: Double?) -> Date {
        Date(timeIntervalSince1970: (milliseconds ?? 0) / 1000)
    }

    static func role(_ raw: String) -> MessageRole {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        default: return .system
        }
    }

    static func toolStatus(_ raw: String?) -> ToolStatus {
        ToolStatus(rawValue: raw ?? "") ?? .pending
    }

    static func errorMessage(_ value: JSONValue) -> String? {
        if let message = value["data"]?["message"]?.stringValue { return message }
        if let name = value["name"]?.stringValue { return name }
        if case .string(let string) = value { return string }
        return value.compactDescription
    }

    static func session(_ session: OCSession) -> AgentSession {
        AgentSession(
            id: session.id,
            agentType: .openCode,
            title: session.title ?? session.id,
            parentID: session.parentID,
            directory: session.directory,
            createdAt: date(session.time?.created),
            updatedAt: date(session.time?.updated ?? session.time?.created)
        )
    }

    static func shell(_ message: OCMessage) -> ChatMessage {
        let messageRole = role(message.role)
        let completed = message.time?.completed
        return ChatMessage(
            id: message.id,
            role: messageRole,
            agentType: .openCode,
            parts: [],
            createdAt: date(message.time?.created),
            completedAt: completed.map(date),
            isStreaming: messageRole == .assistant && completed == nil,
            error: message.error.flatMap(errorMessage)
        )
    }

    static func part(_ part: OCPart) -> MessagePart {
        let kind: MessagePart.Kind
        switch part.type {
        case "text":
            kind = .text(part.text ?? "")
        case "reasoning":
            kind = .reasoning(part.text ?? "")
        case "tool":
            kind = .tool(
                ToolCall(
                    id: part.callID ?? part.id,
                    name: part.tool ?? "tool",
                    status: toolStatus(part.state?.status),
                    input: part.state?.input,
                    output: part.state?.output ?? part.state?.error,
                    title: part.state?.title
                ))
        case "file":
            kind = .file(
                FileReference(path: nil, mime: part.mime, url: part.url, filename: part.filename))
        default:
            kind = .unknown(type: part.type)
        }
        return MessagePart(id: part.id, kind: kind)
    }

    static func message(_ envelope: OCMessageEnvelope) -> ChatMessage {
        var message = shell(envelope.info)
        message.parts = envelope.parts.map(part)
        return message
    }
}
