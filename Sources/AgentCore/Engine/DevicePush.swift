import Foundation

/// An APNs device token, handed to the backend so the server can push
/// turn-completion alerts and silent usage refreshes to the device.
public struct DevicePushRegistration: Sendable, Codable {
    public var token: String
    public var environment: String

    public init(token: String, environment: String) {
        self.token = token
        self.environment = environment
    }

    /// What registering actually left the bridge able to do. A bridge can answer `{"ok":true}`
    /// with no APNs key configured at all — accepting the token is not the same as being able to
    /// push it anywhere — so a caller that needs to know whether it is really covered by a remote
    /// push reads `delivers` rather than the bare success of the call.
    public struct Receipt: Sendable, Equatable {
        /// Whether this bridge holds an APNs client and will really push to this token. `nil` from
        /// a bridge built before it said either way, which must not be read as `false`.
        public var delivers: Bool?

        public init(delivers: Bool? = nil) {
            self.delivers = delivers
        }
    }
}

extension CodingAgentBackend {
    public func registerDeviceToken(_ registration: DevicePushRegistration) async throws {}

    public func unregisterDeviceToken(_ registration: DevicePushRegistration) async throws {}

    /// The receipt a registration left behind, for a backend that can say. Defaults to the plain
    /// registration with no verdict on delivery, so a caller that wants the receipt where one
    /// exists never has to special-case the backends that have none.
    public func registerDeviceTokenReceipt(
        _ registration: DevicePushRegistration
    ) async throws -> DevicePushRegistration.Receipt {
        try await registerDeviceToken(registration)
        return DevicePushRegistration.Receipt()
    }
}
