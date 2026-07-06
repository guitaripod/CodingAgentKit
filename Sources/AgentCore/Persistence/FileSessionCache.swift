import Foundation

/// A `SessionCache` that persists sessions and transcripts as JSON files in a directory.
/// Pure `FileManager`/JSON — no dependencies, works on Linux and Apple. Gives instant cold-start.
public actor FileSessionCache: SessionCache {
    private let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    private func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(raw.map { allowed.contains($0) ? $0 : "_" })
    }

    private func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }
}
