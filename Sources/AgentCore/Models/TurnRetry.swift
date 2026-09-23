import Foundation

/// A turn waiting on its provider between attempts.
///
/// The provider refused or failed the last request (a rate limit, an overloaded model, a plan that
/// ran out), and the server will ask again on its own at ``nextAttemptAt`` unless somebody stops the
/// turn. From the outside that wait is indistinguishable from a model thinking hard: the turn is
/// open, nothing streams, and the one fact that explains it, the provider's own reason, was the
/// thing a client never showed. So it is a state with a name, carried until the next attempt starts
/// answering or the turn ends.
public struct TurnRetry: Sendable, Hashable, Codable {
    /// What the provider says would end the wait, where it said anything (raise a limit, add
    /// credit, upgrade a plan), with the address to do it at.
    public struct Remedy: Sendable, Hashable, Codable {
        public var title: String
        public var message: String
        public var label: String
        public var link: String?

        public init(title: String, message: String, label: String, link: String? = nil) {
            self.title = title
            self.message = message
            self.label = label
            self.link = link
        }
    }

    /// How many times the request has now been tried, counting the one that just failed.
    public var attempt: Int
    /// The provider's own words for why the last attempt failed.
    public var reason: String
    /// When the server will try again, where it said.
    public var nextAttemptAt: Date?
    public var remedy: Remedy?

    public init(attempt: Int, reason: String, nextAttemptAt: Date? = nil, remedy: Remedy? = nil) {
        self.attempt = attempt
        self.reason = reason
        self.nextAttemptAt = nextAttemptAt
        self.remedy = remedy
    }
}
