import AgentCore
import Foundation

/// The last transcript each conversation was read at, with the validator the bridge gave it, so
/// the next read can ask "has it changed?" and be answered in a header.
///
/// A conversation re-reads its transcript on every open and every reconnect, and a phone
/// reconnects every time it wakes; on a long conversation each read was megabytes the bridge had
/// already sent. Shared for the whole process per server, like the stream, because backends are
/// value types and a chat's second backend should find what its first one read. Bounded, because
/// only the conversations somebody is looking at are re-read often enough to be worth holding.
final class BridgeTranscripts: @unchecked Sendable {
    struct Held {
        let etag: String
        let snapshot: TranscriptSnapshot
    }

    static let capacity = 12

    private let lock = NSLock()
    private var held: [String: Held] = [:]
    private var order: [String] = []

    func held(_ sessionID: String) -> Held? {
        lock.withLock { held[sessionID] }
    }

    func hold(_ sessionID: String, etag: String?, snapshot: TranscriptSnapshot) {
        lock.withLock {
            order.removeAll { $0 == sessionID }
            guard let etag else {
                held.removeValue(forKey: sessionID)
                return
            }
            held[sessionID] = Held(etag: etag, snapshot: snapshot)
            order.append(sessionID)
            while order.count > Self.capacity {
                held.removeValue(forKey: order.removeFirst())
            }
        }
    }

    func forget(_ sessionID: String) {
        lock.withLock {
            order.removeAll { $0 == sessionID }
            held.removeValue(forKey: sessionID)
        }
    }
}

/// One cache per server and agent type, keyed like the stream registry: base URL plus
/// credentials, so two profiles on one machine never read each other's copies.
enum BridgeTranscriptRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var caches: [String: BridgeTranscripts] = [:]

    static func transcripts(config: ServerConfig, agentType: AgentType) -> BridgeTranscripts {
        let key = config.baseURL.absoluteString + "|" + agentType.rawValue + "|"
            + (config.credentials?.username ?? "") + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = caches[key] { return existing }
            let created = BridgeTranscripts()
            caches[key] = created
            return created
        }
    }
}
