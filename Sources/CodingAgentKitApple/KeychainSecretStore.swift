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
            var query = baseQuery(for: key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }

        public func setValue(_ value: String, for key: String) throws {
            let attributes: [String: Any] = [
                kSecValueData as String: Data(value.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let status = SecItemUpdate(
                baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var addQuery = baseQuery(for: key)
                addQuery.merge(attributes) { _, new in new }
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw KeychainError.unexpectedStatus(addStatus)
                }
            } else {
                guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
            }
        }

        public func removeValue(for key: String) throws {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
        }

        private func baseQuery(for key: String) -> [String: Any] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
            return query
        }
    }
#endif
