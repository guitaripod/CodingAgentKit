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
}

extension CodingAgentBackend {
    public func registerDeviceToken(_ registration: DevicePushRegistration) async throws {}

    public func unregisterDeviceToken(_ registration: DevicePushRegistration) async throws {}
}
