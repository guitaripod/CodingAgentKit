import Foundation

public protocol SecretStore: Sendable {
    func value(for key: String) throws -> String?
    func setValue(_ value: String, for key: String) throws
    func removeValue(for key: String) throws
}

public struct EnvironmentSecretStore: SecretStore {
    private let prefix: String

    public init(prefix: String = "") {
        self.prefix = prefix
    }

    public func value(for key: String) throws -> String? {
        ProcessInfo.processInfo.environment[prefix + key]
    }

    public func setValue(_ value: String, for key: String) throws {
        throw AgentError.unsupported("EnvironmentSecretStore is read-only")
    }

    public func removeValue(for key: String) throws {
        throw AgentError.unsupported("EnvironmentSecretStore is read-only")
    }
}
