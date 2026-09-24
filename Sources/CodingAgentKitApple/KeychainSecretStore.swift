#if canImport(Security)
    import AgentCore
    import Foundation
    import Security

    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
    }

    /// The Apple platforms' secret store: the data-protection keychain wherever the process may
    /// use it, which is every signed app — the phone, the App Store's Mac build.
    ///
    /// A Mac build signed ad hoc may not, and neither keychain serves it. The data-protection
    /// keychain refuses a process with no application identifier outright, and the login keychain
    /// files every item under the code that wrote it, identified by its hash — which every ad hoc
    /// build changes. So each install asked for the login password once per saved secret, forever,
    /// and teaching a person to type that password into whatever dialog asks for it is worse than
    /// what the prompt protected. Such a build keeps its secrets in a file only its user can read
    /// (`PrivateSecretsFile`), the way command-line tools keep tokens; a secret an earlier build
    /// left in the login keychain is read from there one last time and moved.
    public struct KeychainSecretStore: SecretStore {
        public let service: String
        public let accessGroup: String?

        public init(service: String = "com.codingagentkit.credentials", accessGroup: String? = nil)
        {
            self.service = service
            self.accessGroup = accessGroup
        }

        public func value(for key: String) throws -> String? {
            var item: CFTypeRef?
            var query = protectedQuery(for: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            #if os(macOS)
                if Self.refused(status) { return try privateValue(for: key) }
            #endif
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public func setValue(_ value: String, for key: String) throws {
            let query = protectedQuery(for: key)
            let attributes: [String: Any] = [
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            #if os(macOS)
                if Self.refused(status) {
                    try privateFile.setValue(value, for: key)
                    forgetLoginItem(for: key)
                    return
                }
            #endif
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }

        public func removeValue(for key: String) throws {
            let status = SecItemDelete(protectedQuery(for: key) as CFDictionary)
            #if os(macOS)
                if Self.refused(status) {
                    try privateFile.removeValue(for: key)
                    forgetLoginItem(for: key)
                    return
                }
            #endif
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }

        /// Pins every operation to the data-protection keychain so `kSecAttrAccessible`
        /// and `kSecAttrAccessGroup` behave identically to iOS. Without this, macOS
        /// routes generic-password items to the legacy file keychain, where those
        /// attributes carry different (weaker) semantics. The flag must be present on
        /// add, lookup, update and delete alike, or an item added to one keychain is
        /// invisible to the other.
        private func protectedQuery(for key: String) -> [String: Any] {
            var query = itemQuery(for: key)
            query[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
            return query
        }

        private func itemQuery(for key: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
        }

        #if os(macOS)
            /// Whether the data-protection keychain turned this process away. It says so plainly only
            /// on an add (`errSecMissingEntitlement`); a read, an update or a removal answers
            /// `errSecItemNotFound`, as if it were merely empty. A signed app only reaches the file
            /// for a secret that exists nowhere, and a sandboxed one — the App Store's build, always
            /// signed — never does, because the file and the login keychain are both outside what
            /// its container may read.
            private static func refused(_ status: OSStatus) -> Bool {
                guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else {
                    return false
                }
                return status == errSecMissingEntitlement || status == errSecItemNotFound
            }

            private var privateFile: PrivateSecretsFile { PrivateSecretsFile(service: service) }

            /// The file first. A secret that is not in it yet may be in the login keychain, where
            /// builds before this one kept it: read there the one last time — which may ask — moved
            /// into the file, and removed, which asks nothing. A person who declines that one
            /// question is not asked it again for the rest of the launch, however often the secret
            /// is wanted.
            private func privateValue(for key: String) throws -> String? {
                let file = privateFile
                if let value = try file.value(for: key) { return value }
                let asked = "\(service)\u{0}\(key)"
                guard !Self.declined.contains(asked) else { return nil }
                var item: CFTypeRef?
                var query = itemQuery(for: key)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                if status == errSecAuthFailed || status == errSecUserCanceled {
                    Self.declined.insert(asked)
                }
                guard status == errSecSuccess, let data = item as? Data,
                    let value = String(data: data, encoding: .utf8)
                else { return nil }
                try file.setValue(value, for: key)
                forgetLoginItem(for: key)
                return value
            }

            private static let declined = DeclinedSecrets()

            /// Deleting a login-keychain item needs no authorization, even one another build wrote,
            /// so a secret written or removed here leaves no stale copy for a later build to read.
            private func forgetLoginItem(for key: String) {
                SecItemDelete(itemQuery(for: key) as CFDictionary)
            }
        #endif
    }

    #if os(macOS)
        /// The login-keychain secrets a person has declined to hand over this launch.
        final class DeclinedSecrets: @unchecked Sendable {
            private let lock = NSLock()
            private var keys: Set<String> = []

            func contains(_ key: String) -> Bool { lock.withLock { keys.contains(key) } }
            func insert(_ key: String) { lock.withLock { _ = keys.insert(key) } }
        }

        /// Secrets in a file only its user can read: `Application Support/CodingAgentKit`, one JSON map
        /// per keychain service, created `0600` inside a `0700` directory and replaced whole by a rename,
        /// so there is never a moment when the secrets sit in a file anyone else could open, and never
        /// a half-written one. Every write in the process goes through one lock, because stores are
        /// values handed between threads and each write reads the map before it rewrites it.
        public struct PrivateSecretsFile: Sendable {
            public let url: URL

            public init(url: URL) {
                self.url = url
            }

            public init(service: String) {
                let base =
                    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                    .first ?? FileManager.default.homeDirectoryForCurrentUser
                let name = String(service.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" })
                self.url =
                    base.appendingPathComponent("CodingAgentKit", isDirectory: true)
                    .appendingPathComponent("\(name).secrets.json")
            }

            private static let lock = NSLock()

            public func value(for key: String) throws -> String? {
                try Self.lock.withLock { try read()[key] }
            }

            public func setValue(_ value: String, for key: String) throws {
                try Self.lock.withLock {
                    var all = try read()
                    all[key] = value
                    try write(all)
                }
            }

            public func removeValue(for key: String) throws {
                try Self.lock.withLock {
                    var all = try read()
                    guard all.removeValue(forKey: key) != nil else { return }
                    try write(all)
                }
            }

            /// A file that exists and cannot be read is an error rather than an empty map: treating it
            /// as empty would let the next write replace every secret in it with one.
            private func read() throws -> [String: String] {
                guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
                return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
            }

            private func write(_ all: [String: String]) throws {
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700], ofItemAtPath: directory.path)
                let data = try JSONEncoder().encode(all)
                let staging = directory.appendingPathComponent(
                    ".\(url.lastPathComponent).\(UUID().uuidString)")
                let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                guard descriptor >= 0 else { throw KeychainError.unexpectedStatus(errSecIO) }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do {
                    try handle.write(contentsOf: data)
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                guard rename(staging.path, url.path) == 0 else {
                    try? FileManager.default.removeItem(at: staging)
                    throw KeychainError.unexpectedStatus(errSecIO)
                }
            }
        }
    #endif
#endif
