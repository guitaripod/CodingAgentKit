import Foundation

/// A `SessionCache` that persists sessions and transcripts as JSON files in a directory.
/// Pure `FileManager`/JSON — no dependencies, works on Linux and Apple. Gives instant cold-start.
public actor FileSessionCache: SessionCache {
    private let directory: URL
    private var inUse: Set<String> = []

    /// - Parameter pruning: What a cache directory may keep, applied once per process to each
    ///   directory, off the caller's path. Pass `nil` to keep everything.
    public init(directory: URL, pruning: FileCachePruning? = .standard) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        if let pruning, PrunedDirectories.claim(directory) {
            Task(priority: .utility) { [self] in
                await prune(pruning)
            }
        }
    }

    public func sessions(for agentType: AgentType) async -> [AgentSession] {
        load([AgentSession].self, from: "sessions-\(agentType.rawValue).json") ?? []
    }

    public func store(_ sessions: [AgentSession], for agentType: AgentType) async {
        save(sessions, to: "sessions-\(agentType.rawValue).json")
    }

    public func messages(for sessionID: String) async -> [ChatMessage] {
        let name = "messages-\(sanitize(sessionID)).json"
        inUse.insert(name)
        guard let messages = load([ChatMessage].self, from: name) else { return [] }
        markUsed(name)
        return messages
    }

    public func store(_ messages: [ChatMessage], for sessionID: String) async {
        let name = "messages-\(sanitize(sessionID)).json"
        inUse.insert(name)
        save(messages, to: name)
    }

    /// Removes transcripts nobody has opened for a long time, then the least recently used until
    /// the directory is under its byte cap, and returns the file names removed.
    ///
    /// Runs inside the actor, so it never overlaps a read or a write, and it never removes a
    /// transcript this process has read or written: the conversations in use are exactly those.
    /// Session lists are small and are the cold-start of every launch, so only transcripts are
    /// counted or removed.
    @discardableResult
    func prune(_ policy: FileCachePruning, now: Date = Date()) -> [String] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys)
        else { return [] }
        var entries: [(name: String, modified: Date, size: Int)] = []
        for url in urls where url.lastPathComponent.hasPrefix("messages-") {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            entries.append(
                (
                    url.lastPathComponent, values.contentModificationDate ?? .distantPast,
                    values.fileSize ?? 0
                ))
        }
        entries.sort { $0.modified < $1.modified }
        var total = entries.reduce(0) { $0 + $1.size }
        var removed: [String] = []
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        for entry in entries where !inUse.contains(entry.name) {
            guard entry.modified < cutoff || total > policy.maxBytes else { continue }
            let url = directory.appendingPathComponent(entry.name)
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            total -= entry.size
            removed.append(entry.name)
        }
        return removed
    }

    /// A transcript that was opened is used, whether or not anything in it changed, so reading
    /// one moves it to the safe end of the order the pruner removes in.
    private func markUsed(_ name: String) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: directory.appendingPathComponent(name).path)
    }

    /// Filesystem-safe name that stays collision-free: IDs containing
    /// disallowed characters get a digest suffix so `"a/b"` and `"a.b"`
    /// can never map to the same file.
    func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard raw.contains(where: { !allowed.contains($0) }) else { return raw }
        let cleaned = String(raw.prefix(64).map { allowed.contains($0) ? $0 : "_" })
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "\(cleaned)-\(String(hash, radix: 16))"
    }

    func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let url = directory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: Self.fileWriteOptions)) != nil else { return }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Write options for a cache file. Transcripts routinely carry secrets
    /// (pasted API keys, env dumps, source), so on iOS-family platforms the
    /// file is encrypted at rest with `.completeUntilFirstUserAuthentication`
    /// — the strongest class that still lets `AgentConversation.persist()`
    /// write from the background after the device has been unlocked once
    /// (`.complete` would silently fail every locked-device background write).
    /// Every platform additionally gets `0o600` applied via `posixPermissions`
    /// after the atomic write.
    private static var fileWriteOptions: Data.WritingOptions {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
            return [.atomic]
        #endif
    }
}

/// How much a ``FileSessionCache`` directory may keep.
public struct FileCachePruning: Sendable, Equatable {
    /// A transcript untouched for longer than this is removed.
    public var maxAge: TimeInterval
    /// What the transcripts may add up to; the least recently used go first.
    public var maxBytes: Int

    public init(maxAge: TimeInterval, maxBytes: Int) {
        self.maxAge = maxAge
        self.maxBytes = maxBytes
    }

    public static let standard = FileCachePruning(maxAge: 60 * 86_400, maxBytes: 256 * 1_048_576)
}

/// The directories this process has already pruned, so opening a second cache over one directory
/// does not walk it again.
private enum PrunedDirectories {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var claimed: Set<String> = []

    static func claim(_ directory: URL) -> Bool {
        lock.withLock { claimed.insert(directory.standardizedFileURL.path).inserted }
    }
}
