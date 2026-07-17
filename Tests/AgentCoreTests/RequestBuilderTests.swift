import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

@Suite struct RequestBuilderTests {
    /// A builder over the canonical no-trailing-slash bridge base, optionally authenticated.
    private func builder(base: String = "http://host:4098", credentials: BasicCredentials? = nil)
        -> RequestBuilder
    {
        RequestBuilder(config: ServerConfig(baseURL: URL(string: base)!, credentials: credentials))
    }

    private func absoluteString(_ request: URLRequest) throws -> String {
        try #require(request.url?.absoluteString)
    }

    @Test func plusInQueryValueEncodesAsPercent2BAndNeverStaysLiteral() throws {
        let request = try builder()
            .request(.get, "/file", query: [URLQueryItem(name: "q", value: "a+b")])
        let url = try absoluteString(request)
        #expect(url == "http://host:4098/file?q=a%2Bb")
        #expect(!url.contains("+"))
    }

    @Test func spaceInQueryValueEncodesAsPercent20NotPlus() throws {
        let request = try builder()
            .request(.get, "/file", query: [URLQueryItem(name: "q", value: "a b")])
        let url = try absoluteString(request)
        #expect(url == "http://host:4098/file?q=a%20b")
        #expect(!url.contains("+"))
    }

    @Test func reservedStructuralCharsInValueArePercentEncoded() throws {
        let request = try builder()
            .request(.get, "/file", query: [URLQueryItem(name: "q", value: "a&b=c/d:e")])
        let url = try absoluteString(request)
        #expect(url == "http://host:4098/file?q=a%26b%3Dc%2Fd%3Ae")
        let requestURL = try #require(request.url)
        let query = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedQuery)
        #expect(query == "q=a%26b%3Dc%2Fd%3Ae")
        #expect(!query.dropFirst(2).contains("&"))
        #expect(!query.dropFirst(2).contains("/"))
    }

    @Test func queryItemNameIsAlsoStrictlyEncoded() throws {
        let request = try builder()
            .request(.get, "/file", query: [URLQueryItem(name: "x+y", value: "1")])
        #expect(try absoluteString(request) == "http://host:4098/file?x%2By=1")
    }

    @Test func multipleQueryItemsJoinWithLiteralAmpersandButEncodePlusInValues() throws {
        let request = try builder().request(
            .get, "/x",
            query: [URLQueryItem(name: "a", value: "1"), URLQueryItem(name: "b", value: "2+3")])
        #expect(try absoluteString(request) == "http://host:4098/x?a=1&b=2%2B3")
    }

    @Test func baseWithoutTrailingSlashJoinsPathWithoutLeadingSlash() throws {
        let request = try builder(base: "http://host:4098").request(.get, "sessions")
        #expect(try absoluteString(request) == "http://host:4098/sessions")
    }

    @Test func baseWithTrailingSlashDoesNotDoubleTheSeparator() throws {
        let request = try builder(base: "http://host:4098/").request(.get, "sessions")
        #expect(try absoluteString(request) == "http://host:4098/sessions")
    }

    @Test func leadingSlashPathAgainstBareBaseJoinsWithSingleSlash() throws {
        let request = try builder(base: "http://host:4098").request(.get, "/sessions")
        #expect(try absoluteString(request) == "http://host:4098/sessions")
    }

    @Test func trailingBaseSlashAndLeadingPathSlashCollapseToOne() throws {
        let request = try builder(base: "http://host:4098/").request(.get, "/sessions")
        #expect(try absoluteString(request) == "http://host:4098/sessions")
    }

    @Test func multiSegmentPathPreservesInternalSeparators() throws {
        let request = try builder().request(.get, "/session/abc/message")
        #expect(try absoluteString(request) == "http://host:4098/session/abc/message")
    }

    @Test func authorizationHeaderIsBasicBase64OfDefaultUserAndPassword() throws {
        let request = try builder(credentials: BasicCredentials(password: "secret"))
            .request(.get, "/sessions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic b3BlbmNvZGU6c2VjcmV0")
    }

    @Test func authorizationHeaderBase64CoversColonsInsidePassword() throws {
        let request = try builder(
            credentials: BasicCredentials(username: "alice", password: "p@ss:w0rd"))
            .request(.get, "/sessions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic YWxpY2U6cEBzczp3MHJk")
    }

    @Test func noAuthorizationHeaderWhenCredentialsAbsent() throws {
        let request = try builder().request(.get, "/sessions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.allHTTPHeaderFields?["Authorization"] == nil)
        #expect((request.allHTTPHeaderFields?.count ?? 0) == 1)
    }

    @Test func httpMethodMirrorsTheEnumRawValue() throws {
        let b = builder()
        #expect(try b.request(.get, "/x").httpMethod == "GET")
        #expect(try b.request(.post, "/x").httpMethod == "POST")
        #expect(try b.request(.put, "/x").httpMethod == "PUT")
        #expect(try b.request(.patch, "/x").httpMethod == "PATCH")
        #expect(try b.request(.delete, "/x").httpMethod == "DELETE")
    }

    @Test func acceptHeaderIsAlwaysApplicationJson() throws {
        let request = try builder().request(.get, "/x")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test func contentTypeAndBodyAppearOnlyWhenBodyProvided() throws {
        let body = Data(#"{"k":1}"#.utf8)
        let withBody = try builder().request(.post, "/x", body: body)
        #expect(withBody.httpBody == body)
        #expect(withBody.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let withoutBody = try builder().request(.post, "/x")
        #expect(withoutBody.httpBody == nil)
        #expect(withoutBody.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func authenticatedPostWithBodyCarriesExactlyThreeHeaders() throws {
        let request = try builder(credentials: BasicCredentials(password: "secret"))
            .request(.post, "/x", body: Data("{}".utf8))
        #expect(request.allHTTPHeaderFields?.count == 3)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic b3BlbmNvZGU6c2VjcmV0")
    }

    @Test func customHeadersAreAppliedToTheRequest() throws {
        let request = try builder().request(.get, "/x", headers: ["X-Trace-Id": "abc123"])
        #expect(request.value(forHTTPHeaderField: "X-Trace-Id") == "abc123")
    }

    @Test func eventStreamRequestUsesSSEHeadersAndGetMethod() throws {
        let request = try builder(credentials: BasicCredentials(password: "secret"))
            .eventStreamRequest("/sessions/s1/stream")
        #expect(request.httpMethod == "GET")
        #expect(try absoluteString(request) == "http://host:4098/sessions/s1/stream")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic b3BlbmNvZGU6c2VjcmV0")
    }

    @Test func eventStreamRequestStrictlyEncodesPlusInQuery() throws {
        let request = try builder()
            .eventStreamRequest("/stream", query: [URLQueryItem(name: "since", value: "a+b")])
        #expect(try absoluteString(request) == "http://host:4098/stream?since=a%2Bb")
    }
}
