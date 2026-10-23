import AgentCore
import Foundation

/// Whether this bridge holds a shared queue, learned once from `/status` and remembered for the
/// whole process per server, like the stream: backends are value types, and a chat's second
/// backend should find what its first one learned.
///
/// The answer is held for ten minutes rather than for ever, because a bridge can be updated and
/// restarted while this process still holds it. A stale answer keeps being served until the next
/// probe replaces it, so the capability never flickers off while a probe is out. Only a definite
/// answer is recorded: a bridge that could not be asked right now says nothing about its age.
final class BridgeQueueSupport: @unchecked Sendable {
    private static let ttl: TimeInterval = 600

    private let lock = NSLock()
    private var supported = false
    private var learnedAt: Date?

    var isSupported: Bool { lock.withLock { supported } }

    var needsProbe: Bool {
        lock.withLock {
            guard let learnedAt else { return true }
            return Date().timeIntervalSince(learnedAt) >= Self.ttl
        }
    }

    func record(_ value: Bool) {
        lock.withLock {
            supported = value
            learnedAt = Date()
        }
    }
}

enum BridgeQueueRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var supports: [String: BridgeQueueSupport] = [:]

    static func support(config: ServerConfig, agentType: AgentType) -> BridgeQueueSupport {
        let key = config.baseURL.absoluteString + "|" + agentType.rawValue + "|"
            + (config.credentials?.username ?? "") + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = supports[key] { return existing }
            let created = BridgeQueueSupport()
            supports[key] = created
            return created
        }
    }
}

/// One item of the bridge's queue, as it appears in a snapshot, an event, and the session read.
struct BRQueueItem: Decodable {
    struct Attachment: Decodable {
        let mime: String
        let filename: String?
        let size: Int?
    }

    let id: String
    let text: String
    let kind: String?
    let model: String?
    let effort: String?
    let attachments: [BRLenient<Attachment>]?
    let createdAt: String?

    var item: QueuedPrompt {
        QueuedPrompt(
            id: id, text: text, kind: kind.flatMap(QueuedPrompt.Kind.init) ?? .prompt,
            model: model, effort: effort,
            attachments: (attachments ?? []).compactMap(\.value).map {
                QueuedAttachment(mime: $0.mime, filename: $0.filename, size: $0.size)
            },
            createdAt: createdAt.flatMap(BridgeCoding.date) ?? .distantPast)
    }

    /// The items an array of them holds, skipping one this client cannot read rather than
    /// failing the queue it belongs to.
    static func items(_ raw: [BRLenient<BRQueueItem>]?) -> [QueuedPrompt] {
        (raw ?? []).compactMap(\.value).map(\.item)
    }
}

/// `{"queue":[…],"paused":false}`, which is what every queue route answers, what a `queue` frame
/// carries, and what a hello carries when there is something to say.
struct BRQueue: Decodable {
    let queue: [BRLenient<BRQueueItem>]?
    let paused: Bool?

    var snapshot: QueueSnapshot {
        QueueSnapshot(items: BRQueueItem.items(queue), paused: paused ?? false)
    }
}

/// `POST /sessions/:id/queue`: whether the prompt started at once, and the queue after it.
struct BREnqueued: Decodable {
    let started: Bool
    let queue: [BRLenient<BRQueueItem>]?
    let paused: Bool?

    var result: EnqueueResult {
        EnqueueResult(
            started: started,
            queue: QueueSnapshot(items: BRQueueItem.items(queue), paused: paused ?? false))
    }
}

struct BREnqueue: Encodable {
    let id: String
    let text: String
    let kind: String
    let model: String?
    let effort: String?
    let attachments: [BRSendAttachment]?
}

struct BRQueueEdit: Encodable {
    let text: String?
    let model: String?
    let effort: String?
}

/// The shared queue: claude-bridge and omp-bridge speak it identically, so both agent types get
/// it from this one implementation.
extension ClaudeCodeBackend {
    /// Reads `/status` for `"queue": 1` unless an answer is still fresh. A bridge built before the
    /// queue answers without the field, which is a definite no and is held like a yes.
    func learnQueueSupport() async {
        guard queueSupport.needsProbe else { return }
        let data: Data
        do {
            data = try await http.send(builder.request(.get, "/status"))
        } catch {
            return
        }
        let status = try? BridgeCoding.decoder.decode(BRStatus.self, from: data)
        queueSupport.record((status?.queue ?? 0) >= 1)
    }

    private func requireQueue() async throws {
        await learnQueueSupport()
        guard queueSupport.isSupported else { throw AgentError.unsupported("queue") }
    }

    /// A held copy of the conversation with the queue as the bridge has it now. A 304 says the
    /// transcript is unchanged, and the validator was made for the transcript: the copy held
    /// carries the queue as it stood when it was read, which a queue change since would leave
    /// wrong. So where the bridge keeps a queue it is asked for on its own route; if that cannot
    /// be read the copy is handed back as it was.
    func withCurrentQueue(_ held: TranscriptSnapshot, sessionID: String) async -> TranscriptSnapshot {
        guard queueSupport.isSupported,
            let data = try? await http.send(builder.request(.get, "/sessions/\(sessionID)/queue")),
            let current = try? Self.queueSnapshot(from: data)
        else { return held }
        var snapshot = held
        snapshot.queue = current
        return snapshot
    }

    public func enqueue(sessionID: String, prompt: EnqueuePrompt) async throws -> EnqueueResult {
        try await requireQueue()
        let attachments = prompt.prompt.attachments.compactMap { attachment -> BRSendAttachment? in
            guard let data = attachment.data, !data.isEmpty else { return nil }
            return BRSendAttachment(
                mime: attachment.mime, filename: attachment.filename,
                dataBase64: data.base64EncodedString())
        }
        let body = try BridgeCoding.encoder.encode(
            BREnqueue(
                id: prompt.id, text: prompt.prompt.text, kind: prompt.kind.rawValue,
                model: prompt.prompt.model?.modelID, effort: prompt.prompt.reasoningEffort,
                attachments: attachments.isEmpty ? nil : attachments))
        let data = try await http.send(
            builder.request(.post, "/sessions/\(sessionID)/queue", body: body))
        do {
            return try BridgeCoding.decoder.decode(BREnqueued.self, from: data).result
        } catch {
            throw AgentError.decoding("queue: \(error)")
        }
    }

    public func editQueued(sessionID: String, id: String, edit: QueuedPromptEdit) async throws
        -> QueueSnapshot
    {
        try await requireQueue()
        let body = try BridgeCoding.encoder.encode(
            BRQueueEdit(
                text: edit.text, model: edit.model?.modelID, effort: edit.reasoningEffort))
        return try await changingQueue {
            try await http.send(
                builder.request(.patch, "/sessions/\(sessionID)/queue/\(id)", body: body))
        }
    }

    public func cancelQueued(sessionID: String, id: String) async throws -> QueueSnapshot {
        try await requireQueue()
        return try await changingQueue {
            try await http.send(builder.request(.delete, "/sessions/\(sessionID)/queue/\(id)"))
        }
    }

    public func resumeQueue(sessionID: String) async throws -> QueueSnapshot {
        try await requireQueue()
        return try await changingQueue {
            try await http.send(builder.request(.post, "/sessions/\(sessionID)/queue/resume"))
        }
    }

    /// Runs a request that answers the queue, and reads the bridge's `409 already_started` as the
    /// typed refusal it is rather than as a status code.
    private func changingQueue(_ request: () async throws -> Data) async throws -> QueueSnapshot {
        do {
            return try Self.queueSnapshot(from: try await request())
        } catch AgentError.http(let status, let body)
            where status == 409 && Self.refusalCode(in: body) == "already_started"
        {
            throw QueueError.alreadyStarted
        }
    }

    private static func queueSnapshot(from data: Data) throws -> QueueSnapshot {
        do {
            return try BridgeCoding.decoder.decode(BRQueue.self, from: data).snapshot
        } catch {
            throw AgentError.decoding("queue: \(error)")
        }
    }

    private static func refusalCode(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }
}
