import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// A stand-in bridge that validates the way the real one does: every body carries the tag of its
/// content, and a read that already holds that tag is answered 304 with no body at all.
final class ValidatingBridgeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let sent = request.value(forHTTPHeaderField: "If-None-Match")
        let (body, etag) = ConditionalBridge.shared.answer(path: url.path, ifNoneMatch: sent)
        let status = body == nil ? 304 : 200
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "ETag": etag])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ConditionalBridge: @unchecked Sendable {
    static let shared = ConditionalBridge()

    private let lock = NSLock()
    private var bodies: [String: String] = [:]
    private(set) var validatorsSeen: [String?] = []
    private(set) var fullBodiesSent = 0

    func publish(_ json: String, at path: String) {
        lock.withLock { bodies[path] = json }
    }

    func answer(path: String, ifNoneMatch: String?) -> (Data?, String) {
        lock.withLock {
            let json = bodies[path] ?? "{}"
            let etag = "\"\(json.utf8.count)-\(json.hashValue)\""
            validatorsSeen.append(ifNoneMatch)
            if ifNoneMatch == etag { return (nil, etag) }
            fullBodiesSent += 1
            return (Data(json.utf8), etag)
        }
    }
}

@Suite(.serialized) struct ConditionalTranscriptTests {
    private static func session(_ text: String) -> String {
        #"{"id":"c1","title":"t","messages":[{"id":"m1","role":"assistant","createdAt":"2026-07-17T00:00:00Z","parts":[{"kind":"text","text":"\#(text)"}]}]}"#
    }

    private static func backend() -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ValidatingBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://validating.test:4098")!)
        return ClaudeCodeBackend(config: config, agentType: .claudeCode, http: http)
    }

    private static func text(_ snapshot: TranscriptSnapshot) -> String? {
        guard case .text(let text)? = snapshot.messages.first?.parts.first?.kind else { return nil }
        return text
    }

    /// The whole reason for the validator: a conversation re-read with nothing new in it costs a
    /// header, and the copy that comes back is the one read before, not an empty transcript.
    @Test func anUnchangedTranscriptIsAnsweredWithoutItsBody() async throws {
        let bridge = ConditionalBridge.shared
        bridge.publish(Self.session("first"), at: "/sessions/c1")
        let backend = Self.backend()

        let first = try await backend.transcript(for: "c1")
        let sentBefore = bridge.fullBodiesSent
        let second = try await backend.transcript(for: "c1")

        #expect(Self.text(first) == "first")
        #expect(Self.text(second) == "first")
        #expect(bridge.fullBodiesSent == sentBefore)
        #expect(bridge.validatorsSeen.last != nil)
    }

    /// And a transcript that moved is read in full, with the new copy held for the next read.
    @Test func aChangedTranscriptIsReadInFull() async throws {
        let bridge = ConditionalBridge.shared
        bridge.publish(Self.session("before"), at: "/sessions/c1")
        let backend = Self.backend()
        _ = try await backend.transcript(for: "c1")

        bridge.publish(Self.session("after"), at: "/sessions/c1")
        let moved = try await backend.transcript(for: "c1")
        let sentBefore = bridge.fullBodiesSent
        let again = try await backend.transcript(for: "c1")

        #expect(Self.text(moved) == "after")
        #expect(Self.text(again) == "after")
        #expect(bridge.fullBodiesSent == sentBefore)
    }

    /// A bridge older than validators sends no tag, so nothing is held and nothing is asked:
    /// every read stays a full read, exactly as before.
    @Test func aBridgeWithoutValidatorsIsReadInFullEveryTime() async throws {
        let transcripts = BridgeTranscripts()
        let snapshot = TranscriptSnapshot(messages: [], status: nil, backgroundWork: nil)
        transcripts.hold("s", etag: nil, snapshot: snapshot)
        #expect(transcripts.held("s") == nil)
    }

    /// Only the conversations being looked at are worth holding; the oldest copy goes first.
    @Test func theHeldCopiesAreBounded() {
        let transcripts = BridgeTranscripts()
        let snapshot = TranscriptSnapshot(messages: [], status: nil, backgroundWork: nil)
        for index in 0...BridgeTranscripts.capacity {
            transcripts.hold("s\(index)", etag: "\"\(index)\"", snapshot: snapshot)
        }
        #expect(transcripts.held("s0") == nil)
        #expect(transcripts.held("s\(BridgeTranscripts.capacity)")?.etag == "\"\(BridgeTranscripts.capacity)\"")
    }
}
