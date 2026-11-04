import Foundation

/// The server's model catalog, read at most once every few minutes per server. It is every model
/// every provider offers — 448 of them and a third of a megabyte here — and the composer, the chat
/// and the model sheet each asked for it on their own, so opening a chat read and decoded it again.
/// It changes when the server's configuration does, which a person does far less often than they
/// open a chat; two reads that arrive together share one request.
actor OpenCodeV2ModelCatalog {
    static let freshFor: TimeInterval = 300

    private var held: (models: [OC2Model], at: Date)?
    private var reading: Task<[OC2Model], Error>?

    func models(_ read: @escaping @Sendable () async throws -> [OC2Model]) async throws -> [OC2Model] {
        if let held, Date().timeIntervalSince(held.at) < Self.freshFor { return held.models }
        if let reading { return try await reading.value }
        let task = Task { try await read() }
        reading = task
        defer { reading = nil }
        let models = try await task.value
        held = (models, Date())
        return models
    }
}

enum OpenCodeV2ModelCatalogRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var catalogs: [String: OpenCodeV2ModelCatalog] = [:]

    static func catalog(for client: OpenCodeV2Client) -> OpenCodeV2ModelCatalog {
        let config = client.builder.config
        let key = config.baseURL.absoluteString + "|" + (config.credentials?.username ?? "")
            + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = catalogs[key] { return existing }
            let created = OpenCodeV2ModelCatalog()
            catalogs[key] = created
            return created
        }
    }
}
