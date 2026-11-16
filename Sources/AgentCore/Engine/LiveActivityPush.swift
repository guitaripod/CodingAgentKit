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
    /// Which installation the card is on, so a server following one conversation on a phone and
    /// a tablet pushes to both and never starts a second card where one already stands. Omitted
    /// when nil, as it is from every app before it.
    public var deviceID: String?

    public init(
        token: String, environment: String, startedAt: Date, title: String, endAlert: String? = nil,
        deviceID: String? = nil
    ) {
        self.token = token
        self.environment = environment
        self.startedAt = startedAt
        self.title = title
        self.endAlert = endAlert
        self.deviceID = deviceID
    }
}

/// What a server needs to start a Live Activity on this installation by itself, for a turn the
/// installation did not send: ActivityKit's push-to-start token, which installation it is, and
/// what it should call the conversation's machine and which profile that is, so the card it
/// starts opens the right chat and the app that wakes for it hands the card's token to the right
/// server. `follows` is the person's choice to have turns started elsewhere followed at all;
/// `cardLimit` caps how many cards stand at once; `muted` are the chats never to start one for.
public struct LiveActivityStarter: Sendable, Codable, Equatable {
    public var token: String
    public var deviceID: String
    public var profileID: String
    public var profileName: String
    public var follows: Bool
    public var cardLimit: Int?
    public var muted: [String]?

    public init(
        token: String, deviceID: String, profileID: String, profileName: String, follows: Bool,
        cardLimit: Int? = nil, muted: [String]? = nil
    ) {
        self.token = token
        self.deviceID = deviceID
        self.profileID = profileID
        self.profileName = profileName
        self.follows = follows
        self.cardLimit = cardLimit
        self.muted = muted
    }
}

extension CodingAgentBackend {
    public func registerLiveActivity(
        _ registration: LiveActivityRegistration, for sessionID: String
    ) async throws {}
}
