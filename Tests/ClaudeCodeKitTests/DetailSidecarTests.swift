import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// A stand-in bridge with its own routes and its own counters, answering each path from a table
/// and validating like the real one.
final class DetailBridgeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let key = (url.host ?? "") + url.path
        let (body, etag) = DetailBridge.shared.answer(
            key: key, ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match"))
        let response = HTTPURLResponse(
            url: url, statusCode: body == nil ? 304 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "ETag": etag])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class DetailBridge: @unchecked Sendable {
    static let shared = DetailBridge()

    private let lock = NSLock()
    private var bodies: [String: String] = [:]
    private var reads: [String: Int] = [:]
    private var fullReads: [String: Int] = [:]

    func publish(_ json: String, at key: String) {
        lock.withLock { bodies[key] = json }
    }

    func reads(_ key: String) -> Int { lock.withLock { reads[key, default: 0] } }
    func fullReads(_ key: String) -> Int { lock.withLock { fullReads[key, default: 0] } }

    func answer(key: String, ifNoneMatch: String?) -> (Data?, String) {
        lock.withLock {
            let json = bodies[key] ?? "{}"
            let etag = "\"\(json.utf8.count)-\(json.hashValue)\""
            reads[key, default: 0] += 1
            if ifNoneMatch == etag { return (nil, etag) }
            fullReads[key, default: 0] += 1
            return (Data(json.utf8), etag)
        }
    }
}

/// A refresh reads a conversation once: the session read answers the goal, the cut-off turn and
/// the provider wait beside the messages, and a list that has not moved costs a header.
@Suite struct DetailSidecarTests {
    private static func backend(host: String) -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DetailBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://\(host):4098")!)
        return ClaudeCodeBackend(config: config, agentType: .claudeCode, http: http)
    }

    private static let session = #"""
        {"id":"c1","title":"t","turnOpen":true,
         "messages":[{"id":"m1","role":"assistant","createdAt":"2026-11-04T00:00:00Z","parts":[{"kind":"text","text":"hi"}]},
                     {"id":"m2","role":"assistant","parts":[{"kind":"text","text":"no date, unreadable"}]}],
         "goal":{"condition":"tests pass","met":false},
         "interruption":{"turnID":"t9","prompt":"build it","startedAt":"2026-11-04T00:00:00Z","detectedAt":"2026-11-04T00:05:00Z"},
         "retry":{"attempt":3,"maxRetries":10,"reason":"Anthropic's API is overloaded (529)","status":529,"nextAttemptAt":"2026-11-04T00:06:00Z"}}
        """#

    @Test func aBridgeThatCarriesTheSidecarAnswersEverythingInOneRead() async throws {
        let host = "sidecar.test"
        DetailBridge.shared.publish(#"{"queue":1,"detail":1}"#, at: host + "/status")
        DetailBridge.shared.publish(Self.session, at: host + "/sessions/c1")
        let backend = Self.backend(host: host)

        let snapshot = try await backend.transcript(for: "c1")

        #expect(snapshot.messages.map(\.id) == ["m1"])
        let sidecar = try #require(snapshot.sidecar)
        #expect(sidecar.goal?.condition == "tests pass")
        #expect(sidecar.interruption?.prompt == "build it")
        #expect(snapshot.retry?.attempt == 3)
        #expect(snapshot.retry?.reason == "Anthropic's API is overloaded (529)")
        #expect(snapshot.retry?.nextAttemptAt == ISO8601DateFormatter().date(from: "2026-11-04T00:06:00Z"))
        #expect(backend.capabilities.transcriptCarriesSidecar)

        let goal = try await backend.goal(for: "c1")
        #expect(goal?.condition == "tests pass")
        #expect(DetailBridge.shared.fullReads(host + "/sessions/c1") == 1)
    }

    @Test func aBridgeThatDoesNotSayLeavesTheSidecarUnanswered() async throws {
        let host = "nosidecar.test"
        DetailBridge.shared.publish(#"{"queue":1}"#, at: host + "/status")
        DetailBridge.shared.publish(Self.session, at: host + "/sessions/c1")
        let backend = Self.backend(host: host)

        let snapshot = try await backend.transcript(for: "c1")

        #expect(snapshot.sidecar == nil)
        #expect(!backend.capabilities.transcriptCarriesSidecar)
    }

    @Test func aCopyHeldWithoutTheSidecarIsReadAgainOnceTheBridgeSaysItCarriesOne() async throws {
        let host = "latesidecar.test"
        DetailBridge.shared.publish(#"{"queue":1}"#, at: host + "/status")
        DetailBridge.shared.publish(Self.session, at: host + "/sessions/c1")
        let backend = Self.backend(host: host)
        let before = try await backend.transcript(for: "c1")
        #expect(before.sidecar == nil)

        backend.detailSupport.record(true)
        let after = try await backend.transcript(for: "c1")

        #expect(after.sidecar?.goal?.condition == "tests pass")
        #expect(DetailBridge.shared.fullReads(host + "/sessions/c1") == 2)
        let again = try await backend.transcript(for: "c1")
        #expect(again.sidecar != nil)
        #expect(DetailBridge.shared.fullReads(host + "/sessions/c1") == 2)
    }

    @Test func anUnchangedListCostsAHeader() async throws {
        let host = "list.test"
        DetailBridge.shared.publish(
            #"[{"id":"a","title":"One","updatedAt":"2026-11-04T00:00:00Z"},{"id":"b","title":"Two","updatedAt":"2026-11-03T00:00:00Z"}]"#,
            at: host + "/sessions")
        let backend = Self.backend(host: host)

        let first = try await backend.listSessions()
        let second = try await backend.listSessions()

        #expect(first.map(\.id) == ["a", "b"])
        #expect(second.map(\.id) == ["a", "b"])
        #expect(DetailBridge.shared.reads(host + "/sessions") == 2)
        #expect(DetailBridge.shared.fullReads(host + "/sessions") == 1)
    }
}
