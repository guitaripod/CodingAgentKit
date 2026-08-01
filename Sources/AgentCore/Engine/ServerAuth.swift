import Foundation

/// Whether the agent behind a server is signed in — and, while a sign-in is running, the link the
/// person has to open to finish it.
///
/// A signed-out Claude Code answers every turn with "Not logged in · Please run /login" as if it
/// were a reply, so a client that cannot ask this question shows a conversation that has quietly
/// stopped working.
public struct ServerAuth: Sendable, Hashable, Codable {
    public struct Pending: Sendable, Hashable, Codable {
        /// The account page to open. It ends by handing back a code the server needs typed.
        public var url: String
        public var startedAt: Date

        public init(url: String, startedAt: Date) {
            self.url = url
            self.startedAt = startedAt
        }
    }

    public var loggedIn: Bool
    /// How the server is signed in — `claude.ai` for a subscription, `console` for API billing.
    public var method: String?
    public var email: String?
    public var organization: String?
    /// The plan the account is on, when the server knows it: `max`, `pro`, `free`.
    public var subscription: String?
    public var pending: Pending?

    public init(
        loggedIn: Bool, method: String? = nil, email: String? = nil, organization: String? = nil,
        subscription: String? = nil, pending: Pending? = nil
    ) {
        self.loggedIn = loggedIn
        self.method = method
        self.email = email
        self.organization = organization
        self.subscription = subscription
        self.pending = pending
    }

    /// What to show for the account: the address it belongs to, else the way it signed in.
    public var accountLabel: String? {
        if let email, !email.isEmpty { return email }
        if let organization, !organization.isEmpty { return organization }
        return method
    }
}

/// A backend whose server can be signed in from here.
///
/// The sign-in is a browser flow that ends in a code, so it takes three steps rather than one: ask
/// the server to start, open what it hands back, give it the code that comes out. A server that
/// has never heard of it throws ``AgentError/unsupported(_:)``.
public protocol AuthenticatingBackend: CodingAgentBackend {
    func authStatus() async throws -> ServerAuth
    /// Starts a sign-in and returns the status carrying the link to open.
    func beginSignIn() async throws -> ServerAuth
    /// Hands over the code the browser produced. Returns the status once the server is signed in.
    func submitSignInCode(_ code: String) async throws -> ServerAuth
    func cancelSignIn() async throws
}
