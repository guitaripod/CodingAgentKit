#if canImport(Security)
    import AgentCore
    import Foundation
    import Security

    public enum KeychainError: Error, Sendable {
        case unexpectedStatus(OSStatus)
    }

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
            let status = reaching { keychain in
                var query = baseQuery(for: key, in: keychain)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                return SecItemCopyMatching(query as CFDictionary, &item)
            }
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public func setValue(_ value: String, for key: String) throws {
            let status = reaching { keychain in
                var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
                if keychain == .dataProtection {
                    attributes[kSecAttrAccessible as String] =
                        kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                }
                let query = baseQuery(for: key, in: keychain)
                let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                guard updated == errSecItemNotFound else { return updated }
                return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        }

        public func removeValue(for key: String) throws {
            let status = reaching { keychain in
                SecItemDelete(baseQuery(for: key, in: keychain) as CFDictionary)
            }
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
        private func baseQuery(for key: String, in keychain: Keychain) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            guard keychain == .dataProtection else { return query }
            query[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
            return query
        }

        private enum Keychain { case dataProtection, file }

        /// A Mac build signed ad hoc carries no application identifier, and the data-protection
        /// keychain refuses such a process outright (`errSecMissingEntitlement`) — every save of a
        /// password and every removal of a server would fail. The login keychain accepts it, so the
        /// operation is run there instead; a signed app never reaches the second attempt.
        private func reaching(_ operation: (Keychain) -> OSStatus) -> OSStatus {
            let status = operation(.dataProtection)
            #if os(macOS)
                if status == errSecMissingEntitlement { return operation(.file) }
            #endif
            return status
        }
    }
#endif
