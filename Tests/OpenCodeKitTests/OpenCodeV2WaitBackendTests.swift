import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import OpenCodeKit

/// A stand-in opencode 2 server whose every route this suite cares about is driven by path: the
/// probe/idle wait, the pending forms and permissions, the transcript tail, and the session
/// record a title is read from.
final class WaitServerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let (status, body, contentType) = WaitServer.shared.answer(
            path: url.path, method: request.httpMethod ?? "GET")
        guard status >= 0 else {
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WaitServer: @unchecked Sendable {
    static let shared = WaitServer()

    private let lock = NSLock()
    private var answers: [String: (Int, Data?, String)] = [:]
    /// The wait probe rides a fresh random session id every call, so its answer cannot be keyed
    /// by an exact path the way every other route's can.
    private var waitProbeAnswer: (Int, Data?, String)?
    private var hits: [String: Int] = [:]
    private var waitProbeHits = 0

    func reset() {
        lock.withLock {
            answers.removeAll()
            waitProbeAnswer = nil
            hits.removeAll()
            waitProbeHits = 0
        }
    }

    func publish(
        _ status: Int, _ body: String?, contentType: String = "application/json",
        method: String = "GET", at path: String
    ) {
        lock.withLock { answers["\(method) \(path)"] = (status, body.map { Data($0.utf8) }, contentType) }
    }

    func publishWaitProbe(_ status: Int, _ body: String?, contentType: String = "application/json") {
        lock.withLock { waitProbeAnswer = (status, body.map { Data($0.utf8) }, contentType) }
    }

    /// A negative status is this stub's own signal to fail the connection outright, standing in
    /// for a dropped tailnet hop rather than any answer a real server would give.
    func publishWaitProbeTransportFailure() {
        lock.withLock { waitProbeAnswer = (-1, nil, "") }
    }

    private static func isWaitProbe(path: String, method: String) -> Bool {
        method == "POST" && path.hasPrefix("/api/experimental/session/") && path.hasSuffix("/wait")
    }

    /// The exact id opencode's own session-id validator accepts: `ses_` followed by lowercase
    /// alphanumerics. A probe built any other way (a dashed UUID, an arbitrary prefix) is rejected
    /// with a `400` before the server ever looks the session up — this stub matches that so a
    /// regression in how the Kit builds the probe id is caught without a live server.
    private static func sessionID(from waitPath: String) -> String? {
        let segments = waitPath.split(separator: "/")
        guard segments.count == 5, segments[0] == "api", segments[1] == "experimental",
            segments[2] == "session", segments[4] == "wait"
        else { return nil }
        return String(segments[3])
    }

    private static func hasOpencodeSessionIDShape(_ id: String) -> Bool {
        guard id.hasPrefix("ses_") else { return false }
        let suffix = id.dropFirst("ses_".count)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    private static let invalidSessionIDAnswer: (Int, Data?, String) = (
        400,
        Data(#"{"_tag":"InvalidRequestError","message":"Invalid session ID","field":"sessionID"}"#.utf8),
        "application/json"
    )

    func answer(path: String, method: String) -> (Int, Data?, String) {
        lock.withLock {
            if Self.isWaitProbe(path: path, method: method) {
                waitProbeHits += 1
                guard let id = Self.sessionID(from: path), Self.hasOpencodeSessionIDShape(id) else {
                    return Self.invalidSessionIDAnswer
                }
                return waitProbeAnswer ?? (404, nil, "text/html")
            }
            let key = "\(method) \(path)"
            hits[key, default: 0] += 1
            return answers[key] ?? (404, nil, "text/html")
        }
    }

    func hitCount(method: String, path: String) -> Int {
        lock.withLock { hits["\(method) \(path)"] ?? 0 }
    }

    var waitProbeHitCount: Int { lock.withLock { waitProbeHits } }
}

@Suite(.serialized) struct OpenCodeV2WaitBackendTests {
    private static func backend(sessionID: String = "ses_1") -> OpenCodeV2Backend {
        WaitServer.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitServerProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://waiting-oc2.test:4096")!)
        let client = OpenCodeV2Client(config: config, http: http)
        return OpenCodeV2Backend(client: client)
    }

    private static func publishNoPendingUI(sessionID: String) {
        WaitServer.shared.publish(
            200, #"{"data":[]}"#, at: "/api/session/\(sessionID)/form")
        WaitServer.shared.publish(
            200, #"{"data":[]}"#, at: "/api/session/\(sessionID)/permission")
    }

    /// The probe answers exactly once for the life of the backend — a server does not gain the
    /// route mid-process, so a second call must be served from the cache rather than asking again.
    @Test func supportIsProbedOnceAndCached() async {
        let backend = Self.backend()
        WaitServer.shared.publishWaitProbe(
            404, #"{"_tag":"SessionNotFoundError","sessionID":"x","message":"gone"}"#)

        let first = await backend.turnWaitSupport()
        let second = await backend.turnWaitSupport()

        #expect(first == .supported)
        #expect(second == .supported)
        #expect(WaitServer.shared.waitProbeHitCount == 1)
    }

    /// A dropped connection is never remembered as either answer — it is asked again next time,
    /// and once the tunnel recovers the real answer is found and then held.
    @Test func aTransportFailureIsUndeterminedAndNotCached() async {
        let backend = Self.backend()
        WaitServer.shared.publishWaitProbeTransportFailure()
        let first = await backend.turnWaitSupport()
        #expect(first == .undetermined)

        WaitServer.shared.publishWaitProbe(
            404, #"{"_tag":"SessionNotFoundError","sessionID":"x","message":"gone"}"#)
        let second = await backend.turnWaitSupport()
        #expect(second == .supported)
        #expect(WaitServer.shared.waitProbeHitCount == 2)
    }

    @Test func anUnsupportedServerOffersNoRequest() async throws {
        let backend = Self.backend()
        WaitServer.shared.publishWaitProbe(200, "<html></html>", contentType: "text/html")
        #expect(try await backend.turnWaitRequest(for: "ses_1") == nil)
    }

    @Test func aSupportedServerOffersAnUploadingPostRequest() async throws {
        let backend = Self.backend()
        WaitServer.shared.publishWaitProbe(
            404, #"{"_tag":"SessionNotFoundError","sessionID":"x","message":"gone"}"#)
        let request = try await backend.turnWaitRequest(for: "ses_1")
        #expect(request?.uploadsEmptyBody == true)
        #expect(request?.request.url?.path == "/api/experimental/session/ses_1/wait")
        #expect(request?.request.httpMethod == "POST")
    }

    @Test func anythingButTwoOhFourThrows() async {
        let backend = Self.backend()
        await #expect(throws: (any Error).self) {
            try await backend.turnWaitResult(
                status: 503, headers: [:], body: Data(), sessionID: "ses_1")
        }
    }

    @Test func aPendingFormOutranksTheTranscript() async throws {
        let backend = Self.backend()
        WaitServer.shared.publish(
            200, #"{"data":[{"id":"f1","sessionID":"ses_1","fields":[]}]}"#,
            at: "/api/session/ses_1/form")
        let result = try await backend.turnWaitResult(
            status: 204, headers: [:], body: Data(), sessionID: "ses_1")
        #expect(result.state == .needsYou)
        #expect(result.ending == .question)
    }

    @Test func aPendingPermissionOutranksTheTranscript() async throws {
        let backend = Self.backend()
        WaitServer.shared.publish(200, #"{"data":[]}"#, at: "/api/session/ses_1/form")
        WaitServer.shared.publish(
            200, #"{"data":[{"id":"p1","sessionID":"ses_1"}]}"#,
            at: "/api/session/ses_1/permission")
        let result = try await backend.turnWaitResult(
            status: 204, headers: [:], body: Data(), sessionID: "ses_1")
        #expect(result.state == .needsYou)
        #expect(result.ending == .approval)
    }

    @Test func anIdleTurnWithNothingPendingReadsTheTranscriptTail() async throws {
        let backend = Self.backend()
        Self.publishNoPendingUI(sessionID: "ses_1")
        WaitServer.shared.publish(
            200,
            #"""
            {"data":[
              {"id":"msg_U","time":{"created":1000},"text":"go","type":"user"},
              {"id":"msg_A1","time":{"created":1010,"completed":1020},"type":"assistant","agent":"build","content":[{"type":"text","text":"done"}],"finish":"stop"}
            ]}
            """#,
            at: "/api/session/ses_1/message")
        WaitServer.shared.publish(
            200, #"{"data":{"id":"ses_1","title":"A session"}}"#, at: "/api/session/ses_1")

        let result = try await backend.turnWaitResult(
            status: 204, headers: [:], body: Data(), sessionID: "ses_1")
        #expect(result.state == .ended)
        #expect(result.ending == .finished)
        #expect(result.title == "A session")
        #expect(result.lastMessageID == "msg_A1")
    }

    @Test func aTailWithNoAssistantMessageStillReportsEnded() async throws {
        let backend = Self.backend()
        Self.publishNoPendingUI(sessionID: "ses_1")
        WaitServer.shared.publish(
            200, #"{"data":[{"id":"msg_U","time":{"created":1000},"text":"go","type":"user"}]}"#,
            at: "/api/session/ses_1/message")
        WaitServer.shared.publish(200, #"{"data":{"id":"ses_1"}}"#, at: "/api/session/ses_1")

        let result = try await backend.turnWaitResult(
            status: 204, headers: [:], body: Data(), sessionID: "ses_1")
        #expect(result.state == .ended)
        #expect(result.ending == .finished)
        #expect(result.lastMessageID == nil)
    }
}
