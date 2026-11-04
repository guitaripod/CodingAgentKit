import AgentCore
import Foundation

/// One `/api/event` connection per opencode 2 server, shared by everything watching it.
///
/// The route carries every workspace's events with the session named on each frame, so one socket
/// is enough for a whole server — yet every open conversation, every watched session on the Agents
/// board and the chat list each opened their own, and each read and decoded the whole server's
/// traffic to keep the sliver that was theirs. A phone with five chats open held six firehoses to
/// one machine. Now the first subscriber dials, every later one joins the same stream, and the last
/// one to leave hangs it up.
///
/// A subscriber that joins a connection already open is handed the `server.connected` frame it
/// missed first, because that frame is when a conversation reads its inbox. When the connection
/// ends, every subscriber's stream ends the same way — with the error, or cleanly — and each
/// reconnects on its own clock exactly as it did with a socket of its own; the next subscribe
/// dials again.
actor OpenCodeV2EventHub {
    typealias Stream = AsyncThrowingStream<SSEvent, Error>

    private let open: @Sendable () -> Stream
    private var subscribers: [UUID: Stream.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private var connectedFrame: SSEvent?
    private var generation = 0

    init(open: @escaping @Sendable () -> Stream) {
        self.open = open
    }

    func subscribe() -> Stream {
        let id = UUID()
        let (stream, continuation) = Stream.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.drop(id) }
        }
        if let connectedFrame { continuation.yield(connectedFrame) }
        if pump == nil { dial() }
        return stream
    }

    var subscriberCount: Int { subscribers.count }

    private func dial() {
        generation += 1
        let dialled = generation
        let source = open()
        pump = Task { [weak self] in
            do {
                for try await event in source {
                    await self?.deliver(event, generation: dialled)
                }
                await self?.end(nil, generation: dialled)
            } catch {
                await self?.end(error, generation: dialled)
            }
        }
    }

    private func deliver(_ event: SSEvent, generation dialled: Int) {
        guard dialled == generation else { return }
        if event.data.contains("server.connected"),
            OpenCodeV2EventDecoder.frame(event)?.type == "server.connected"
        {
            connectedFrame = event
        }
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func end(_ error: Error?, generation dialled: Int) {
        guard dialled == generation else { return }
        pump = nil
        connectedFrame = nil
        let ending = subscribers
        subscribers = [:]
        for continuation in ending.values {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    private func drop(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty else { return }
        generation += 1
        pump?.cancel()
        pump = nil
        connectedFrame = nil
    }
}

/// One hub per server and credentials, like the bridge's stream registry: backends are value types,
/// and a conversation's backend and the chat list's backend must find the same connection.
enum OpenCodeV2EventHubRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hubs: [String: OpenCodeV2EventHub] = [:]

    static func hub(for client: OpenCodeV2Client) -> OpenCodeV2EventHub {
        let config = client.builder.config
        let key = config.baseURL.absoluteString + "|" + (config.credentials?.username ?? "")
            + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = hubs[key] { return existing }
            let created = OpenCodeV2EventHub(open: { client.eventStream() })
            hubs[key] = created
            return created
        }
    }
}
