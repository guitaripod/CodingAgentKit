import AgentCore
import Foundation
import Testing

@testable import PreviewKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class TouchHostProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let (status, body) = TouchHost.shared.answer(for: request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client.urlProtocol(self, didLoad: Data(body.utf8)) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class TouchHost: @unchecked Sendable {
    static let shared = TouchHost()

    private let lock = NSLock()
    private var status = 204
    private var body = ""
    private(set) var requests: [(method: String, path: String, body: Data)] = []

    func reset(status: Int = 204, body: String = "") {
        lock.withLock {
            self.status = status
            self.body = body
            requests = []
        }
    }

    func answer(for request: URLRequest) -> (Int, String) {
        let sent = Self.bytes(of: request)
        return lock.withLock {
            requests.append((request.httpMethod ?? "", request.url?.path ?? "", sent))
            return (status, body)
        }
    }

    private static func bytes(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized) struct TouchTests {
    private func client() throws -> PreviewClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TouchHostProtocol.self]
        let config = try #require(PreviewClient.config(host: "mac.test", password: nil))
        return PreviewClient(config: config, http: HTTPClient(session: URLSession(configuration: configuration)))
    }

    private func sent() throws -> [String: Any] {
        let last = try #require(TouchHost.shared.requests.last)
        return try #require(JSONSerialization.jsonObject(with: last.body) as? [String: Any])
    }

    @Test func aTapIsPostedAsFractionsOfThePicture() async throws {
        TouchHost.shared.reset()
        try await client().touch("abc123", .tap(x: 0.25, y: 0.75))
        let request = try #require(TouchHost.shared.requests.last)
        #expect(request.method == "POST")
        #expect(request.path == "/sessions/abc123/touch")
        let json = try sent()
        #expect(json["action"] as? String == "tap")
        #expect(json["x"] as? Double == 0.25)
        #expect(json["y"] as? Double == 0.75)
        #expect(json["text"] == nil)
    }

    @Test func aSwipeCarriesBothEndsAndItsDuration() async throws {
        TouchHost.shared.reset()
        try await client().touch("abc123", .swipe(x: 0.5, y: 0.8, toX: 0.5, toY: 0.2, seconds: 0.4))
        let json = try sent()
        #expect(json["action"] as? String == "swipe")
        #expect(json["toY"] as? Double == 0.2)
        #expect(json["seconds"] as? Double == 0.4)
    }

    @Test func textKeysAndButtonsAreNamedByWhatTheyAre() async throws {
        TouchHost.shared.reset()
        let client = try client()
        try await client.touch("abc123", .text("hello"))
        #expect(try sent()["text"] as? String == "hello")
        try await client.touch("abc123", .key("return"))
        #expect(try sent()["key"] as? String == "return")
        try await client.touch("abc123", .button("home"))
        #expect(try sent()["button"] as? String == "home")
    }

    @Test func aRefusalSurfacesTheHostsStatus() async throws {
        TouchHost.shared.reset(status: 409, body: #"{"error":"The app is not showing yet"}"#)
        do {
            try await client().touch("abc123", .tap(x: 0.5, y: 0.5))
            Issue.record("a 409 should have thrown")
        } catch AgentError.http(let status, let body) {
            #expect(status == 409)
            #expect(body.contains("not showing"))
        }
    }

    @Test func theRequestRoundTripsThroughTheSharedWire() throws {
        let request = TouchRequest.swipe(x: 0.1, y: 0.2, toX: 0.3, toY: 0.4)
        let decoded = try PreviewJSON.decoder.decode(TouchRequest.self, from: PreviewJSON.encoder.encode(request))
        #expect(decoded == request)
    }
}
