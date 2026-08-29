import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore

/// Records every outgoing request's `timeoutInterval` and answers a canned 200,
/// so the contract under test is the one the Kit owns: the per-send deadline
/// must reach the transport as the request's own timeout, instead of the
/// session configuration's budget travelling with every call.
final class RecordingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url?.absoluteString {
            box.store(url: url, timeout: request.timeoutInterval)
        }
        guard let endpoint = request.url, let client = client else { return }
        let data = Data("ok".utf8)
        let response = HTTPURLResponse(
            url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

}

private let box = TimeoutStore()

private final class TimeoutStore: @unchecked Sendable {
    private var values: [String: TimeInterval] = [:]
    private let lock = NSLock()

    func store(url: String, timeout: TimeInterval) {
        lock.lock()
        values[url] = timeout
        lock.unlock()
    }

    func value(for url: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return values[url]
    }
}



private func stubbedSessionClient() -> HTTPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingURLProtocol.self]
    let session = URLSession(configuration: configuration)
    return HTTPClient(session: session)
}

@Suite struct HTTPClientTimeoutTests {
    @Test func perRequestTimeoutReachesTransport() async throws {
        let client = stubbedSessionClient()
        let url = URL(string: "http://slow.test/summarize")!
        try await client.send(URLRequest(url: url), timeout: .seconds(900))
        #expect(box.value(for: url.absoluteString) == 900)
    }

    /// Without an explicit timeout the session-constructed client's default
    /// budget travels with the request, so ordinary routes keep today's behavior.
    @Test func defaultSendUsesPolicyTimeout() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = HTTPClient(session: session)
        let url = URL(string: "http://slow.test/health")!
        try await client.send(URLRequest(url: url))
        #expect(box.value(for: url.absoluteString) == 30)
    }
}