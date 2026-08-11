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

    /// Whether the transcript can say where a text delta lands.
    ///
    /// A delta that names a part is answered by that part. A delta that names only its message is
    /// answered by the message existing at all, because the block it belongs to is whichever one
    /// that message is currently being written into. A message the transcript has never held
    /// answers neither, and that is exactly the divergence a refetch exists to heal.
    public func canAddress(messageID: String, partID: String?) -> Bool {
        guard let index = indexByID[messageID] else { return false }
        guard let partID else { return true }
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
            guard let partID else {
                editExisting(messageID) { message in
                    Self.appendStreamedText(delta, to: &message)
                }
                return
            }
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
        case .status, .goal, .compaction, .permission, .permissionResolved, .question,
            .questionResolved, .failure,
            .unknown:
            break
        }
    }

    /// Puts a delta that named no part where the answer is currently being written: on the end of
    /// the message's last part when that part is text, and in a new text block when it is not.
    ///
    /// A backend whose deltas carry no part id (claude-bridge) can only be routed against the
    /// transcript as it actually stands. A decoder counting text blocks of its own gets this right
    /// only while it has watched the whole message from its first token — open a chat mid-turn, or
    /// take a stream gap, and a fresh counter routes the live answer into the message's *first*
    /// paragraph, above the tool calls, until the next full message rewrites everything at once.
    /// The last part is the one still growing, and a tool call landing after it is exactly what
    /// ends a text block, so the rule needs no memory at all.
    private static func appendStreamedText(_ delta: String, to message: inout ChatMessage) {
        if let last = message.parts.last, case .text = last.kind {
            message.parts[message.parts.count - 1].appendText(delta)
        } else {
            message.parts.append(MessagePart(id: nextTextPartID(in: message), kind: .text(delta)))
        }
    }

    /// The id a newly opened text block takes, numbered from how many the message already has so
    /// it matches the `text`/`text-N` scheme a backend's own full-message payload will carry — a
    /// streamed block and the snapshot that later replaces it have to be the same row.
    private static func nextTextPartID(in message: ChatMessage) -> String {
        var index = message.parts.reduce(into: 0) { count, part in
            if case .text = part.kind { count += 1 }
        }
        var candidate = index == 0 ? "text" : "text-\(index)"
        while message.parts.contains(where: { $0.id == candidate }) {
            index += 1
            candidate = "text-\(index)"
        }
        return candidate
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
        if let finishReason = message.finishReason { existing.finishReason = finishReason }
        if replaceParts { existing.parts = message.parts }
    }

    /// Edits a message the transcript already holds, and does nothing at all when it does not.
    ///
    /// A delta that named no part addresses whatever block its message is currently being written
    /// into, and only a message that exists can answer that. Fabricating a shell to hold one would
    /// put a bubble on screen that starts mid-sentence, invented from a transcript this device has
    /// already diverged from — the engine's answer to that divergence is a refetch, so the delta is
    /// dropped here rather than turned into a message the server never reported.
    private mutating func editExisting(_ id: String, _ body: (inout ChatMessage) -> Void) {
        guard let index = indexByID[id] else { return }
        body(&messages[index])
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
