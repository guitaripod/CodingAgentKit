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

        /// Throws on transient read failures (e.g. data-protection lock) instead of
        /// returning `[]`, so `save`/`delete` can never rebuild the file from an
        /// empty read and silently drop every stored profile.
        public func profiles() throws -> [ConnectionProfile] {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)
            {
                return []
            }
            return try JSONDecoder().decode([ConnectionProfile].self, from: data)
        }

        /// Keychain first: if the password write fails, no profile lands on
        /// disk, so a failed save can't leave a half-saved profile that
        /// becomes active (and 401s) on the next launch.
        public func save(_ profile: ConnectionProfile, password: String?) throws {
            var all = try profiles().filter { $0.id != profile.id }
            all.append(profile)
            if let password { try keychain.setValue(password, for: profile.id) }
            try write(all)
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
