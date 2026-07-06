import Foundation

public struct BasicCredentials: Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String = "opencode", password: String) {
        self.username = username
        self.password = password
    }

    public var authorizationHeaderValue: String {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

public struct ServerConfig: Sendable, Hashable {
    public var baseURL: URL
    public var credentials: BasicCredentials?

    public init(baseURL: URL, credentials: BasicCredentials? = nil) {
        self.baseURL = baseURL
        self.credentials = credentials
    }
}
