import Foundation

public struct MessageReducer: Sendable {
    public let agentType: AgentType
    private var messages: [ChatMessage] = []
    private var indexByID: [String: Int] = [:]

    public init(agentType: AgentType, messages: [ChatMessage] = []) {
        self.agentType = agentType
        for message in messages {
            upsert(message, replaceParts: true)
        }
    }

    public var snapshot: [ChatMessage] { messages }

    public func hasPart(messageID: String, partID: String) -> Bool {
        guard let index = indexByID[messageID] else { return false }
        return messages[index].parts.contains { $0.id == partID }
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
            remove(messageID)
        case .status, .permission, .question, .questionResolved, .failure, .unknown:
            break
        }
    }

    private mutating func upsert(_ message: ChatMessage, replaceParts: Bool) {
        if let index = indexByID[message.id] {
            merge(message, into: &messages[index], replaceParts: replaceParts)
        } else {
            indexByID[message.id] = messages.count
            messages.append(message)
        }
    }

    /// Merges an incoming upsert into the stored message, preserving known metadata when the
    /// incoming message omits it. Backends emit metadata-free message updates mid-stream and
    /// only fill cost, tokens, provider, and model on completion, so nil fields must never
    /// erase values learned from earlier events.
    private func merge(
        _ message: ChatMessage, into existing: inout ChatMessage, replaceParts: Bool
    ) {
        existing.role = message.role
        existing.completedAt = message.completedAt
        existing.isStreaming = message.isStreaming
        if let error = message.error { existing.error = error }
        if let costUSD = message.costUSD { existing.costUSD = costUSD }
        if let providerID = message.providerID { existing.providerID = providerID }
        if let modelID = message.modelID { existing.modelID = modelID }
        if let totalTokens = message.totalTokens { existing.totalTokens = totalTokens }
        if replaceParts { existing.parts = message.parts }
    }

    private mutating func edit(_ id: String, _ body: (inout ChatMessage) -> Void) {
        if let index = indexByID[id] {
            body(&messages[index])
        } else {
            var shell = ChatMessage(
                id: id, role: .assistant, agentType: agentType, createdAt: Date())
            body(&shell)
            indexByID[id] = messages.count
            messages.append(shell)
        }
    }

    private mutating func remove(_ id: String) {
        guard let index = indexByID.removeValue(forKey: id) else { return }
        messages.remove(at: index)
        reindex(from: index)
    }

    private mutating func reindex(from start: Int) {
        for index in start..<messages.count {
            indexByID[messages[index].id] = index
        }
    }
}
