import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// A stand-in bridge for the ticket route: a new one answers with a URL, one that cannot read the
/// file says so in JSON, and one from before tickets answers 404 with nothing.
final class TicketBridgeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let (status, body) = TicketBridge.shared.answer(host: url.host ?? "", path: url.path)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TicketBridge: @unchecked Sendable {
    static let shared = TicketBridge()

    func answer(host: String, path: String) -> (Int, String) {
        guard path == "/files/ticket" else { return (404, "") }
        switch host {
        case "new.test":
            return (200, #"{"url":"/files/raw?ticket=abc123","size":42,"mime":"video/mp4"}"#)
        case "missing.test":
            return (404, #"{"error":"not readable"}"#)
        default:
            return (404, "")
        }
    }
}

@Suite(.serialized) struct ServerFileTicketTests {
    private static func backend(_ host: String) -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://\(host):4098")!)
        return ClaudeCodeBackend(config: config, agentType: .claudeCode, http: http)
    }

    private static let clip = ServerFile.reference(
        path: "/home/me/Clips/demo cut.mp4", mime: "video/mp4", revision: "m7")

    @Test func aReferenceCarriesItsPathUnderTheRawRoute() {
        let file = Self.clip
        #expect(file.url == "/files/raw?path=%2Fhome%2Fme%2FClips%2Fdemo%20cut.mp4&rev=m7")
        #expect(file.filename == "demo cut.mp4")
        #expect(ServerFile.path(of: file) == "/home/me/Clips/demo cut.mp4")
    }

    @Test func theRevisionTellsTheSamePathApart() {
        let earlier = ServerFile.reference(path: "/tmp/a.png", mime: "image/png", revision: "m1")
        let later = ServerFile.reference(path: "/tmp/a.png", mime: "image/png", revision: "m9")
        #expect(earlier.url != later.url)
        #expect(ServerFile.path(of: earlier) == ServerFile.path(of: later))
    }

    @Test func otherReferencesNameNoServerPath() {
        #expect(ServerFile.path(of: FileReference(path: "/tmp/a.png", mime: "image/png")) == nil)
        #expect(ServerFile.path(of: FileReference(url: "data:image/png;base64,AAAA")) == nil)
        #expect(ServerFile.path(of: FileReference(url: "/attachments/s1/a.png")) == nil)
    }

    @Test func aNewBridgeHandsBackAnAbsoluteTicketURL() async throws {
        let url = try await Self.backend("new.test").streamingURL(for: Self.clip)
        #expect(url?.absoluteString == "http://new.test:4098/files/raw?ticket=abc123")
    }

    @Test func aBridgeFromBeforeTicketsAnswersNil() async throws {
        let url = try await Self.backend("old.test").streamingURL(for: Self.clip)
        #expect(url == nil)
    }

    @Test func aMissingFileIsAnErrorNotAnOldBridge() async {
        await #expect(throws: AgentError.self) {
            _ = try await Self.backend("missing.test").streamingURL(for: Self.clip)
        }
    }
}
