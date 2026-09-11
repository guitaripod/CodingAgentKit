import Foundation

public struct MessageReducer: Sendable {
    public let agentType: AgentType
    private var messages: [ChatMessage] = []
    private var indexByID: [String: Int] = [:]
    /// Second names for messages this transcript already holds, by the name the copy arrived
    /// under. See ``renamedCopy(of:)``.
    private var aliases: [String: String] = [:]

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
        guard let index = indexByID[aliases[messageID] ?? messageID] else { return false }
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
                    var incoming = part
                    if incoming.startedAt == nil {
                        incoming.startedAt = message.parts[index].startedAt
                    }
                    message.parts[index] = incoming
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
        case .status, .goal, .compaction, .interruption, .backgroundWork, .attached, .detached,
            .resync, .permission, .permissionResolved, .question, .questionResolved, .failure,
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
        if let held = aliases[message.id], let index = indexByID[held] {
            mergeCopy(message, into: index)
        } else if let index = indexByID[message.id] {
            merge(message, into: &messages[index], replaceParts: replaceParts)
        } else if let index = renamedCopy(of: message) {
            aliases[message.id] = messages[index].id
            mergeCopy(message, into: index)
        } else {
            indexByID[message.id] = messages.count
            messages.append(message)
        }
    }

    /// The message this one is a second account of, if it is one.
    ///
    /// A backend can hold one conversation in two records that name messages differently — the
    /// Claude bridge streams a turn under ids its store mints and reads the same turn back off the
    /// CLI's JSONL under the ids of the lines — and a server bug that lets the second name leak
    /// hands a client the answer it has just watched arrive as a message it has never seen. Kept,
    /// it stands on screen twice until a refetch replaces the transcript, and the replacement is
    /// the flash a reader sees. So an assistant message under an unknown name, arriving while the
    /// newest answer of the same turn already says the same thing, is taken as that answer again.
    ///
    /// The bar is deliberately narrow, because merging two messages that are really two is worse
    /// than showing one twice: only the newest assistant message with words since the last prompt
    /// is a candidate, and the words have to match — equal, or one the whole opening of the other —
    /// over a length no two different sentences of a turn share by chance.
    private func renamedCopy(of message: ChatMessage) -> Int? {
        guard message.role == .assistant else { return nil }
        let incoming = Self.words(of: message)
        guard incoming.count >= Self.renameEvidence else { return nil }
        let prompt = messages.lastIndex { $0.role == .user } ?? -1
        guard
            let index = messages.indices.reversed().first(where: {
                $0 > prompt && messages[$0].role == .assistant
                    && !Self.words(of: messages[$0]).isEmpty
            })
        else { return nil }
        let held = Self.words(of: messages[index])
        guard min(held.count, incoming.count) >= Self.renameEvidence,
            held.hasPrefix(incoming) || incoming.hasPrefix(held)
        else { return nil }
        return index
    }

    /// How much of an answer two copies have to agree on before they are one answer.
    private static let renameEvidence = 80

    /// A second account only ever adds to the first. Its metadata fills what the held copy lacks;
    /// its parts are taken only when they carry more words than the held copy has, because the
    /// part ids are the copy's own and replacing equal parts would re-key every row the answer
    /// already drew — the flash, without the duplicate.
    private mutating func mergeCopy(_ message: ChatMessage, into index: Int) {
        let fuller = Self.words(of: message).count > Self.words(of: messages[index]).count
        merge(message, into: &messages[index], replaceParts: fuller)
    }

    private static func words(of message: ChatMessage) -> String {
        message.parts.reduce(into: "") { text, part in
            if case .text(let value) = part.kind { text += value }
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
        if let usage = message.usage { existing.usage = usage }
        if let context = message.context { existing.context = context }
        if let duration = message.duration { existing.duration = duration }
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
        guard aliases[id] == nil, let index = indexByID[id] else { return }
        body(&messages[index])
    }

    /// A part addressed to a second name is a part of a copy this transcript already holds under
    /// its first one, and it is left there: the copy's part ids are not the held message's, so
    /// applying them would write the same words into the answer a second time.
    private mutating func edit(_ id: String, _ body: (inout ChatMessage) -> Void) {
        guard aliases[id] == nil else { return }
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
        guard aliases.removeValue(forKey: id) == nil else { return }
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
