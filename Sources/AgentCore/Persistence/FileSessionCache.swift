import Foundation

/// A `SessionCache` that persists sessions and transcripts as JSON files in a directory.
/// Pure `FileManager`/JSON — no dependencies, works on Linux and Apple. Gives instant cold-start.
public actor FileSessionCache: SessionCache {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func sessions(for agentType: AgentType) async -> [AgentSession] {
        load([AgentSession].self, from: "sessions-\(agentType.rawValue).json") ?? []
    }

    public func store(_ sessions: [AgentSession], for agentType: AgentType) async {
        save(sessions, to: "sessions-\(agentType.rawValue).json")
    }

    public func messages(for sessionID: String) async -> [ChatMessage] {
        load([ChatMessage].self, from: "messages-\(sanitize(sessionID)).json") ?? []
    }

    public func store(_ messages: [ChatMessage], for sessionID: String) async {
        save(messages, to: "messages-\(sanitize(sessionID)).json")
    }

    /// Filesystem-safe name that stays collision-free: IDs containing
    /// disallowed characters get a digest suffix so `"a/b"` and `"a.b"`
    /// can never map to the same file.
    private func sanitize(_ raw: String) -> String {
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

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
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
