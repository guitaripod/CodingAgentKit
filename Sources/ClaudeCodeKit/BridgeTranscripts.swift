import AgentCore
import Foundation

/// The last transcript each conversation was read at, with the validator the bridge gave it, so
/// the next read can ask "has it changed?" and be answered in a header.
///
/// A conversation re-reads its transcript on every open and every reconnect, and a phone
/// reconnects every time it wakes; on a long conversation each read was megabytes the bridge had
/// already sent. Shared for the whole process per server, like the stream, because backends are
/// value types and a chat's second backend should find what its first one read. Bounded by count
/// and by bytes, because only the conversations somebody is looking at are re-read often enough
/// to be worth holding, and one long conversation is megabytes.
final class BridgeTranscripts: @unchecked Sendable {
    struct Held {
        let etag: String
        let snapshot: TranscriptSnapshot
        let bytes: Int
    }

    static let capacity = 12

    /// What the held copies may add up to, counted in the bytes the bridge sent for them. The copy
    /// read last is always kept, however large, because it is the one the next read asks about.
    static let byteBudget = 64 * 1_048_576

    /// How long a copy nobody has asked about is kept. A conversation somebody is looking at asks
    /// every few seconds; one that was closed never asks again, and its copy was megabytes held
    /// for as long as the process lived on every server it had ever read from.
    static let idleLife: TimeInterval = 600

    private let lock = NSLock()
    private let clock: @Sendable () -> Date
    private var held: [String: Held] = [:]
    private var asked: [String: Date] = [:]
    private var order: [String] = []
    private var heldBytes = 0

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }
    private var list: (etag: String, sessions: [AgentSession])?

    /// The session list as last read, with its validator. A list is re-read on every stream
    /// reconnect and every invalidation, and on a machine with hundreds of conversations most of
    /// those reads find it exactly as it was.
    var heldList: (etag: String, sessions: [AgentSession])? { lock.withLock { list } }

    func holdList(etag: String?, sessions: [AgentSession]) {
        lock.withLock { list = etag.map { ($0, sessions) } }
    }

    func held(_ sessionID: String) -> Held? {
        lock.withLock {
            sweep()
            guard let copy = held[sessionID] else { return nil }
            asked[sessionID] = clock()
            return copy
        }
    }

    func hold(_ sessionID: String, etag: String?, snapshot: TranscriptSnapshot, bytes: Int = 0) {
        lock.withLock {
            drop(sessionID)
            guard let etag else { return }
            held[sessionID] = Held(etag: etag, snapshot: snapshot, bytes: bytes)
            asked[sessionID] = clock()
            heldBytes += bytes
            order.append(sessionID)
            sweep()
            while order.count > Self.capacity || (heldBytes > Self.byteBudget && order.count > 1) {
                drop(order[0])
            }
        }
    }

    func forget(_ sessionID: String) {
        lock.withLock { drop(sessionID) }
    }

    var totalBytes: Int { lock.withLock { heldBytes } }

    var heldIDs: [String] { lock.withLock { order } }

    /// Lets go of every copy and the list, for a process the system has asked for memory back.
    /// The next read of each is simply answered in full.
    func releaseAll() {
        lock.withLock {
            held = [:]
            asked = [:]
            order = []
            heldBytes = 0
            list = nil
        }
    }

    /// Drops the copies nobody has asked about within ``idleLife``. Called with the lock held, on
    /// the reads and writes that happen anyway, so nothing here needs a clock of its own.
    private func sweep() {
        let now = clock()
        for id in order where now.timeIntervalSince(asked[id] ?? now) > Self.idleLife { drop(id) }
    }

    private func drop(_ sessionID: String) {
        asked[sessionID] = nil
        order.removeAll { $0 == sessionID }
        if let removed = held.removeValue(forKey: sessionID) { heldBytes -= removed.bytes }
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

    static func releaseAll() {
        let all = lock.withLock { Array(caches.values) }
        for cache in all { cache.releaseAll() }
    }
}

/// The transcripts and lists this process keeps to be answered "unchanged" by a bridge. A client
/// that has been asked for memory back lets go of them here; nothing is lost but the saving, since
/// the next read of each is answered in full.
public enum HeldTranscripts {
    public static func release() {
        BridgeTranscriptRegistry.releaseAll()
    }
}
