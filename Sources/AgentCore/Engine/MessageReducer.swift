import Foundation

public struct MessageReducer: Sendable {
    public let agentType: AgentType
    private var order: [String] = []
    private var storage: [String: ChatMessage] = [:]

    public init(agentType: AgentType, messages: [ChatMessage] = []) {
        self.agentType = agentType
        for message in messages {
            upsert(message, replaceParts: true)
        }
    }

    public var snapshot: [ChatMessage] {
        order.compactMap { storage[$0] }
    }

    public mutating func apply(_ event: BackendEvent) {
        switch event {
        case .messageUpserted(let message, let replaceParts):
            upsert(message, replaceParts: replaceParts)
        case .partUpserted(let messageID, let part):
            edit(messageID) { message in
                if let index = message.parts.firstIndex(where: { $0.id == part.id }) {
                    message.parts[index] = part
                } else {
                    message.parts.append(part)
                }
            }
        case .partTextDelta(let messageID, let partID, let delta):
            edit(messageID) { message in
                if let index = message.parts.firstIndex(where: { $0.id == partID }) {
                    message.parts[index].appendText(delta)
                } else {
                    message.parts.append(MessagePart(id: partID, kind: .text(delta)))
                }
            }
        case .partRemoved(let messageID, let partID):
            edit(messageID) { message in
                message.parts.removeAll { $0.id == partID }
            }
        case .messageRemoved(let messageID):
            storage[messageID] = nil
            order.removeAll { $0 == messageID }
        case .status, .permission, .failure, .unknown:
            break
        }
    }

    private mutating func upsert(_ message: ChatMessage, replaceParts: Bool) {
        if var existing = storage[message.id] {
            existing.role = message.role
            existing.completedAt = message.completedAt
            existing.isStreaming = message.isStreaming
            if let error = message.error { existing.error = error }
            if replaceParts { existing.parts = message.parts }
            storage[message.id] = existing
        } else {
            storage[message.id] = message
            order.append(message.id)
        }
    }

    private mutating func edit(_ id: String, _ body: (inout ChatMessage) -> Void) {
        if var message = storage[id] {
            body(&message)
            storage[id] = message
        } else {
            var shell = ChatMessage(
                id: id, role: .assistant, agentType: agentType, createdAt: Date())
            body(&shell)
            storage[id] = shell
            order.append(id)
        }
    }
}
