import Foundation

/// A per-activity ActivityKit push token, handed to the backend so the server
/// can drive Live Activity updates over APNs while the app is suspended.
public struct LiveActivityRegistration: Sendable, Codable {
    public var token: String
    public var environment: String
    public var startedAt: Date
    public var title: String
    /// What the server does to the card when the turn ends: `"silent"` alerts without a sound so
    /// the Dynamic Island opens on how it ended, `"sound"` alerts with one, and nil settles it in
    /// place. A wire word, added and never renamed; omitted from the body when nil, so a bridge
    /// from before it reads the registration exactly as it always did.
    public var endAlert: String?

    public init(
        token: String, environment: String, startedAt: Date, title: String, endAlert: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.startedAt = startedAt
        self.title = title
        self.endAlert = endAlert
    }
}

extension CodingAgentBackend {
    public func registerLiveActivity(
        _ registration: LiveActivityRegistration, for sessionID: String
    ) async throws {}
}
