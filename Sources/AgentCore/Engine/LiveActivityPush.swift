import Foundation

/// A per-activity ActivityKit push token, handed to the backend so the server
/// can drive Live Activity updates over APNs while the app is suspended.
public struct LiveActivityRegistration: Sendable, Codable {
    public var token: String
    public var environment: String
    public var startedAt: Date
    public var title: String

    public init(token: String, environment: String, startedAt: Date, title: String) {
        self.token = token
        self.environment = environment
        self.startedAt = startedAt
        self.title = title
    }
}

extension CodingAgentBackend {
    public func registerLiveActivity(
        _ registration: LiveActivityRegistration, for sessionID: String
    ) async throws {}
}
