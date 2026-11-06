import Foundation

/// An APNs device token, handed to the backend so the server can push
/// turn-completion alerts and silent usage refreshes to the device.
public struct DevicePushRegistration: Sendable, Codable {
    public var token: String
    public var environment: String
    /// What the person wants to hear about, so the server that holds the work pushes only that.
    /// Nil leaves the server's own default, which is what a device that predates the rules sends.
    public var rules: DevicePushRules?

    public init(token: String, environment: String, rules: DevicePushRules? = nil) {
        self.token = token
        self.environment = environment
        self.rules = rules
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

/// A device's notification choices as a bridge reads them. Words are the device's own; this is
/// only the decision: when finished work is news (`settled`, `everyTurn`, `failures`, `never`),
/// the shortest work worth a notice in seconds, whether approvals and questions are, and the
/// chats whose finished work says nothing. A field a bridge does not know is left alone, and one
/// a device leaves out is the bridge's default.
public struct DevicePushRules: Sendable, Codable, Equatable {
    public var finish: String
    public var minimumWork: Int?
    public var needsYou: Bool?
    public var muted: [String]?

    public init(finish: String, minimumWork: Int? = nil, needsYou: Bool? = nil, muted: [String]? = nil) {
        self.finish = finish
        self.minimumWork = minimumWork
        self.needsYou = needsYou
        self.muted = muted
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
