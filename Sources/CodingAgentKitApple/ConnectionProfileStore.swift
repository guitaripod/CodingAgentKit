#if canImport(Security)
    import AgentCore
    import Foundation

    /// Serializes the read-modify-write cycle behind `save`/`delete` so two threads
    /// sharing a store can't both read the old `profiles.json`, edit, and write back
    /// — which would silently drop one thread's change (last writer wins).
    private final class WriteLock: @unchecked Sendable {
        private let lock = NSLock()
        func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try body()
        }
    }

    /// Stores connection profiles (metadata on disk, passwords in the Keychain) for an app.
    public struct ConnectionProfileStore: Sendable {
        public let directory: URL
        private let keychain: KeychainSecretStore
        private let writeLock = WriteLock()

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
        /// becomes active (and 401s) on the next launch. The whole
        /// read-modify-write runs under `writeLock` so concurrent saves serialize.
        public func save(_ profile: ConnectionProfile, password: String?) throws {
            try writeLock.withLock {
                var all = try profiles().filter { $0.id != profile.id }
                all.append(profile)
                if let password { try keychain.setValue(password, for: profile.id) }
                try write(all)
            }
        }

        /// Transactional so a partial failure leaves neither an orphaned Keychain
        /// secret nor an active-but-passwordless profile: the remaining list is
        /// computed first (a failing read aborts before any mutation), the secret
        /// is backed up and removed, then the file is rewritten — and if that
        /// write throws, the secret is restored so the profile stays intact with
        /// its password rather than 401ing on next launch.
        public func delete(id: String) throws {
            try writeLock.withLock {
                let remaining = try profiles().filter { $0.id != id }
                let backup = try? keychain.value(for: id)
                try keychain.removeValue(for: id)
                do {
                    try write(remaining)
                } catch {
                    if let backup { try? keychain.setValue(backup, for: id) }
                    throw error
                }
            }
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
