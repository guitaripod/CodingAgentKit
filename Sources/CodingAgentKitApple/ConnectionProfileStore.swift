#if canImport(Security)
    import AgentCore
    import Foundation

    /// Stores connection profiles (metadata on disk, passwords in the Keychain) for an app.
    public struct ConnectionProfileStore: Sendable {
        public let directory: URL
        private let keychain: KeychainSecretStore

        public init(
            directory: URL? = nil,
            keychain: KeychainSecretStore = KeychainSecretStore()
        ) throws {
            if let directory {
                self.directory = directory
            } else {
                let base = try FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                self.directory = base.appendingPathComponent("CodingAgentKit", isDirectory: true)
            }
            self.keychain = keychain
            try FileManager.default.createDirectory(
                at: self.directory, withIntermediateDirectories: true)
        }

        private var fileURL: URL { directory.appendingPathComponent("profiles.json") }

        public func profiles() throws -> [ConnectionProfile] {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            return try JSONDecoder().decode([ConnectionProfile].self, from: data)
        }

        public func save(_ profile: ConnectionProfile, password: String?) throws {
            var all = try profiles().filter { $0.id != profile.id }
            all.append(profile)
            try write(all)
            if let password { try keychain.setValue(password, for: profile.id) }
        }

        public func delete(id: String) throws {
            try write(try profiles().filter { $0.id != id })
            try keychain.removeValue(for: id)
        }

        public func password(for id: String) throws -> String? {
            try keychain.value(for: id)
        }

        public func makeBackend(
            _ profile: ConnectionProfile,
            policy: ConnectionPolicy = .default
        ) throws -> any CodingAgentBackend {
            profile.makeBackend(password: try password(for: profile.id), policy: policy)
        }

        private func write(_ profiles: [ConnectionProfile]) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        }
    }
#endif
