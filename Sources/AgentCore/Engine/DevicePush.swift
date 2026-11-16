import Foundation

/// An APNs device token, handed to the backend so the server can push
/// turn-completion alerts and silent usage refreshes to the device.
public struct DevicePushRegistration: Sendable, Codable {
    public var token: String
    public var environment: String
    /// What the person wants to hear about, so the server that holds the work pushes only that.
    /// Nil leaves the server's own default, which is what a device that predates the rules sends.
    public var rules: DevicePushRules?
    /// How the server may start this installation's Live Activities itself; nil from a device
    /// that cannot, or that predates it, and the server then starts none.
    public var liveActivity: LiveActivityStarter?
    /// Which installation this is, the same id its Live Activity registrations carry, so a server
    /// applies the device's rules to its cards whether or not it can start them.
    public var deviceID: String?

    public init(
        token: String, environment: String, rules: DevicePushRules? = nil,
        liveActivity: LiveActivityStarter? = nil, deviceID: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.rules = rules
        self.liveActivity = liveActivity
        self.deviceID = deviceID
    }

    /// What registering actually left the bridge able to do. A bridge can answer `{"ok":true}`
    /// with no APNs key configured at all — accepting the token is not the same as being able to
    /// push it anywhere — so a caller that needs to know whether it is really covered by a remote
    /// push reads `delivers` rather than the bare success of the call.
    public struct Receipt: Sendable, Equatable {
        /// Whether this bridge holds an APNs client and will really push to this token. `nil` from
        /// a bridge built before it said either way, which must not be read as `false`.
        public var delivers: Bool?
        /// Whether the bridge took the device's push-to-start token and will start Live
        /// Activities for turns the device did not send. Nil from a bridge that cannot, which a
        /// device hands the token to again whenever it comes forward, so a bridge updated since
        /// learns it without the app being relaunched.
        public var startsCards: Bool?

        public init(delivers: Bool? = nil, startsCards: Bool? = nil) {
            self.delivers = delivers
            self.startsCards = startsCards
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
    /// Hold this device's notices while the person is at a desk (``DeskPresence``) and hand them
    /// over, the ones still unread, once they have left. Nil or false: push as always.
    public var quietAtDesk: Bool?
    /// Seconds without input before the person counts as away from a desk; the bridge's default
    /// when nil.
    public var awayAfter: Int?

    public init(
        finish: String, minimumWork: Int? = nil, needsYou: Bool? = nil, muted: [String]? = nil,
        quietAtDesk: Bool? = nil, awayAfter: Int? = nil
    ) {
        self.finish = finish
        self.minimumWork = minimumWork
        self.needsYou = needsYou
        self.muted = muted
        self.quietAtDesk = quietAtDesk
        self.awayAfter = awayAfter
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
