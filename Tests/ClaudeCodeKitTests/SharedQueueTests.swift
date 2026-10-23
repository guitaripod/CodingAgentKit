import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// A stand-in bridge for the shared queue: every answer is looked up by host, method and path, so
/// each test owns a bridge of its own, and every request it receives is kept with its body.
final class QueueBridgeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let bridge = QueueBridge.named(url.host ?? "")
        let sent = request.value(forHTTPHeaderField: "If-None-Match")
        let answer = bridge.answer(
            method: request.httpMethod ?? "GET", path: url.path, body: Self.body(of: request),
            ifNoneMatch: sent)
        guard answer.status >= 0 else {
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var headers = ["Content-Type": "application/json"]
        if let etag = answer.etag { headers["ETag"] = etag }
        let response = HTTPURLResponse(
            url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = answer.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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

final class QueueBridge: @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: Data?
        var etag: String?
    }

    struct Seen {
        let method: String
        let path: String
        let body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bridges: [String: QueueBridge] = [:]

    static func named(_ host: String) -> QueueBridge {
        lock.withLock {
            if let existing = bridges[host] { return existing }
            let created = QueueBridge()
            bridges[host] = created
            return created
        }
    }

    private let guarded = NSLock()
    private var answers: [String: Answer] = [:]
    private var requests: [Seen] = []

    func publish(
        _ status: Int, _ body: String?, etag: String? = nil, method: String = "GET", at path: String
    ) {
        guarded.withLock {
            answers["\(method) \(path)"] = Answer(
                status: status, body: body.map { Data($0.utf8) }, etag: etag)
        }
    }

    func publishTransportFailure(method: String = "GET", at path: String) {
        guarded.withLock { answers["\(method) \(path)"] = Answer(status: -1) }
    }

    func answer(method: String, path: String, body: Data?, ifNoneMatch: String?) -> Answer {
        guarded.withLock {
            requests.append(Seen(method: method, path: path, body: body))
            guard let answer = answers["\(method) \(path)"] else { return Answer(status: 404) }
            if let etag = answer.etag, etag == ifNoneMatch {
                return Answer(status: 304, body: nil, etag: etag)
            }
            return answer
        }
    }

    func hits(_ method: String, _ path: String) -> Int {
        guarded.withLock { requests.filter { $0.method == method && $0.path == path }.count }
    }

    func lastBody(_ method: String, _ path: String) -> [String: Any]? {
        guarded.withLock {
            requests.last { $0.method == method && $0.path == path }?.body.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        }
    }
}

private func backend(host: String, agentType: AgentType = .claudeCode) -> ClaudeCodeBackend {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QueueBridgeProtocol.self]
    let http = HTTPClient(session: URLSession(configuration: configuration))
    let config = ServerConfig(baseURL: URL(string: "http://\(host):4098")!)
    return ClaudeCodeBackend(config: config, agentType: agentType, http: http)
}

private let itemJSON =
    #"{"id":"q1","text":"then run the tests","kind":"prompt","model":"opus","effort":"high","attachments":[{"mime":"image/png","filename":"a.png","size":12345}],"createdAt":"2026-10-23T10:00:00Z"}"#

@Suite struct QueueFrameDecodingTests {
    private func decode(_ json: String) -> BackendEvent? {
        var decoder = BridgeEventDecoder()
        return decoder.decode(SSEvent(id: nil, type: nil, data: json))
    }

    @Test func aQueueFrameCarriesTheWholeQueue() {
        let event = decode(#"{"type":"queue","queue":[\#(itemJSON)],"paused":true}"#)
        guard case .queue(let snapshot)? = event else {
            Issue.record("expected a queue event, got \(String(describing: event))")
            return
        }
        #expect(snapshot.paused)
        let first = snapshot.items.first
        #expect(first?.id == "q1")
        #expect(first?.text == "then run the tests")
        #expect(first?.kind == .prompt)
        #expect(first?.model == "opus")
        #expect(first?.effort == "high")
        #expect(first?.attachments == [QueuedAttachment(mime: "image/png", filename: "a.png", size: 12345)])
        #expect(first?.createdAt == Date(timeIntervalSince1970: 1_792_749_600))
    }

    @Test func anEmptyQueueIsAFrameToo() {
        guard case .queue(let snapshot)? = decode(#"{"type":"queue","queue":[],"paused":false}"#)
        else {
            Issue.record("expected a queue event")
            return
        }
        #expect(snapshot.isEmpty)
        #expect(!snapshot.paused)
    }

    @Test func aFrameWithNoQueueInItIsNotAnEmptyQueue() {
        #expect(decode(#"{"type":"queue","paused":false}"#) == nil)
    }

    @Test func aHelloCarriesTheQueueOnlyWhenThereIsOne() {
        guard case .queue(let snapshot)? = decode(
            #"{"type":"hello","queue":[\#(itemJSON)],"paused":false}"#)
        else {
            Issue.record("expected a queue event")
            return
        }
        #expect(snapshot.items.map(\.id) == ["q1"])
        #expect(decode(#"{"type":"hello"}"#) == nil)
    }

    @Test func aCommandAndAnUnreadableItemAreTolerated() {
        guard case .queue(let snapshot)? = decode(
            #"{"type":"queue","queue":[{"id":"c","text":"/compact","kind":"command"},{"nope":1},{"id":"x","text":"t","kind":"future"}],"paused":false}"#)
        else {
            Issue.record("expected a queue event")
            return
        }
        #expect(snapshot.items.map(\.id) == ["c", "x"])
        #expect(snapshot.items.map(\.kind) == [.command, .prompt])
    }

    @Test func theSessionReadCarriesTheQueueAndItsPause() throws {
        let session = try BridgeCoding.decoder.decode(
            BRSession.self,
            from: Data(
                #"{"id":"s1","title":"t","messages":[],"queue":[\#(itemJSON)],"queuePaused":true}"#
                    .utf8))
        #expect(BRQueueItem.items(session.queue).map(\.id) == ["q1"])
        #expect(session.queuePaused == true)

        let old = try BridgeCoding.decoder.decode(
            BRSession.self, from: Data(#"{"id":"s1","title":"t","messages":[]}"#.utf8))
        #expect(old.queue == nil)
    }
}

@Suite(.serialized) struct QueueCapabilityTests {
    @Test func aBridgeThatReportsTheQueueGetsTheCapabilityOnItsFirstRead() async throws {
        let host = "capable.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        bridge.publish(200, #"{"id":"s1","title":"t","messages":[]}"#, at: "/sessions/s1")
        let backend = backend(host: host)
        #expect(!backend.capabilities.supportsServerQueue)

        _ = try await backend.transcript(for: "s1")

        #expect(backend.capabilities.supportsServerQueue)
        #expect(backend.capabilities.supportsQueueEdit)
    }

    @Test func aBridgeWithoutTheFieldStaysWithoutTheCapability() async throws {
        let host = "old.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"turnWait":1}"#, at: "/status")
        bridge.publish(200, #"{"id":"s1","title":"t","messages":[]}"#, at: "/sessions/s1")
        let backend = backend(host: host)

        _ = try await backend.transcript(for: "s1")

        #expect(!backend.capabilities.supportsServerQueue)
        #expect(!backend.capabilities.supportsQueueEdit)
        await #expect(throws: AgentError.unsupported("queue")) {
            try await backend.enqueue(
                sessionID: "s1", prompt: EnqueuePrompt(prompt: SendPrompt(text: "hi")))
        }
        #expect(bridge.hits("POST", "/sessions/s1/queue") == 0)
    }

    @Test func theAnswerIsReadOncePerServerAndSharedByEveryBackendForIt() async throws {
        let host = "shared.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        bridge.publish(200, #"{"id":"s1","title":"t","messages":[]}"#, at: "/sessions/s1")
        let first = backend(host: host)

        _ = try await first.transcript(for: "s1")
        _ = try await first.transcript(for: "s1")
        let second = backend(host: host)

        #expect(second.capabilities.supportsServerQueue)
        #expect(bridge.hits("GET", "/status") == 1)
    }

    @Test func aBridgeThatCouldNotBeAskedIsAskedAgainRatherThanLatchedAsOld() async throws {
        let host = "flaky.test"
        let bridge = QueueBridge.named(host)
        bridge.publishTransportFailure(at: "/status")
        bridge.publish(200, #"{"id":"s1","title":"t","messages":[]}"#, at: "/sessions/s1")
        let backend = backend(host: host)

        _ = try await backend.transcript(for: "s1")
        #expect(!backend.capabilities.supportsServerQueue)

        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        _ = try await backend.transcript(for: "s1")
        #expect(backend.capabilities.supportsServerQueue)
    }

    @Test func aHealthCheckLearnsItToo() async throws {
        let host = "health.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"version":"9.9.9","queue":1}"#, at: "/status")
        let backend = backend(host: host)

        let health = try await backend.health()

        #expect(health.version == "9.9.9")
        #expect(backend.capabilities.supportsServerQueue)
    }

    @Test func theOhMyPiBridgeSpeaksTheSameWire() async throws {
        let host = "omp.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        bridge.publish(200, #"{"started":false,"queue":[\#(itemJSON)],"paused":false}"#, method: "POST", at: "/sessions/s1/queue")
        let omp = backend(host: host, agentType: .omp)

        let result = try await omp.enqueue(
            sessionID: "s1", prompt: EnqueuePrompt(id: "q1", prompt: SendPrompt(text: "hi")))

        #expect(omp.capabilities.supportsServerQueue)
        #expect(!result.started)
    }
}

@Suite(.serialized) struct QueueRouteTests {
    private static func ready(_ host: String) -> (ClaudeCodeBackend, QueueBridge) {
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        return (backend(host: host), bridge)
    }

    @Test func anEnqueueSendsTheItemUnderItsIdAndReadsWhetherItStarted() async throws {
        let (backend, bridge) = Self.ready("enqueue.test")
        bridge.publish(
            200, #"{"started":false,"queue":[\#(itemJSON)],"paused":false}"#, method: "POST",
            at: "/sessions/s1/queue")

        let result = try await backend.enqueue(
            sessionID: "s1",
            prompt: EnqueuePrompt(
                id: "q1", kind: .command,
                prompt: SendPrompt(
                    text: "/compact", model: ModelSelection(providerID: "anthropic", modelID: "opus"),
                    reasoningEffort: "high",
                    attachments: [PromptAttachment(mime: "image/png", filename: "a.png", data: Data([1, 2, 3]))])))

        #expect(!result.started)
        #expect(result.queue.items.map(\.id) == ["q1"])
        let sent = try #require(bridge.lastBody("POST", "/sessions/s1/queue"))
        #expect(sent["id"] as? String == "q1")
        #expect(sent["text"] as? String == "/compact")
        #expect(sent["kind"] as? String == "command")
        #expect(sent["model"] as? String == "opus")
        #expect(sent["effort"] as? String == "high")
        let attachments = try #require(sent["attachments"] as? [[String: Any]])
        #expect(attachments.first?["dataBase64"] as? String == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func aPromptThatStartedAtOnceSaysSo() async throws {
        let (backend, bridge) = Self.ready("started.test")
        bridge.publish(
            200, #"{"started":true,"queue":[],"paused":false}"#, method: "POST",
            at: "/sessions/s1/queue")

        let result = try await backend.enqueue(
            sessionID: "s1", prompt: EnqueuePrompt(prompt: SendPrompt(text: "now")))

        #expect(result.started)
        #expect(result.queue.isEmpty)
    }

    @Test func anEditPatchesOnlyWhatWasGiven() async throws {
        let (backend, bridge) = Self.ready("edit.test")
        bridge.publish(
            200, #"{"queue":[\#(itemJSON)],"paused":false}"#, method: "PATCH",
            at: "/sessions/s1/queue/q1")

        let snapshot = try await backend.editQueued(
            sessionID: "s1", id: "q1", edit: QueuedPromptEdit(text: "new words"))

        #expect(snapshot.items.map(\.id) == ["q1"])
        let sent = try #require(bridge.lastBody("PATCH", "/sessions/s1/queue/q1"))
        #expect(sent["text"] as? String == "new words")
        #expect(sent["model"] == nil)
        #expect(sent["effort"] == nil)
    }

    @Test func aCancelDeletesTheItem() async throws {
        let (backend, bridge) = Self.ready("cancel.test")
        bridge.publish(
            200, #"{"queue":[],"paused":false}"#, method: "DELETE", at: "/sessions/s1/queue/q1")

        let snapshot = try await backend.cancelQueued(sessionID: "s1", id: "q1")

        #expect(snapshot.isEmpty)
        #expect(bridge.hits("DELETE", "/sessions/s1/queue/q1") == 1)
    }

    @Test func aResumeLiftsThePause() async throws {
        let (backend, bridge) = Self.ready("resume.test")
        bridge.publish(
            200, #"{"queue":[\#(itemJSON)],"paused":false}"#, method: "POST",
            at: "/sessions/s1/queue/resume")

        let snapshot = try await backend.resumeQueue(sessionID: "s1")

        #expect(!snapshot.paused)
        #expect(snapshot.items.count == 1)
    }

    @Test func aConflictAboutAStartedItemIsATypedRefusal() async throws {
        let (backend, bridge) = Self.ready("conflict.test")
        bridge.publish(
            409, #"{"error":"already_started"}"#, method: "PATCH", at: "/sessions/s1/queue/q1")
        bridge.publish(
            409, #"{"error":"already_started"}"#, method: "DELETE", at: "/sessions/s1/queue/q1")

        await #expect(throws: QueueError.alreadyStarted) {
            try await backend.editQueued(
                sessionID: "s1", id: "q1", edit: QueuedPromptEdit(text: "late"))
        }
        await #expect(throws: QueueError.alreadyStarted) {
            try await backend.cancelQueued(sessionID: "s1", id: "q1")
        }
    }

    @Test func anyOtherConflictStaysAnHTTPError() async throws {
        let (backend, bridge) = Self.ready("other.test")
        bridge.publish(
            409, #"{"error":"busy"}"#, method: "DELETE", at: "/sessions/s1/queue/q1")

        await #expect(throws: AgentError.http(status: 409, body: #"{"error":"busy"}"#)) {
            try await backend.cancelQueued(sessionID: "s1", id: "q1")
        }
    }

    @Test func theTypedRefusalHasWordsForAPerson() {
        #expect(QueueError.alreadyStarted.errorDescription?.isEmpty == false)
    }
}

@Suite(.serialized) struct QueueTranscriptTests {
    @Test func aReadCarriesTheQueueAndItsPause() async throws {
        let host = "read.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        bridge.publish(
            200,
            #"{"id":"s1","title":"t","messages":[],"queue":[\#(itemJSON)],"queuePaused":true}"#,
            at: "/sessions/s1")
        let backend = backend(host: host)

        let snapshot = try await backend.transcript(for: "s1")

        #expect(snapshot.queue?.items.map(\.id) == ["q1"])
        #expect(snapshot.queue?.paused == true)
    }

    @Test func aBridgeWithoutAQueueSaysNothingAboutIt() async throws {
        let host = "silent.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true}"#, at: "/status")
        bridge.publish(200, #"{"id":"s1","title":"t","messages":[]}"#, at: "/sessions/s1")
        let backend = backend(host: host)

        let snapshot = try await backend.transcript(for: "s1")

        #expect(snapshot.queue == nil)
    }

    @Test func anUnchangedTranscriptStillCarriesTheQueueAsItIsNow() async throws {
        let host = "etag.test"
        let bridge = QueueBridge.named(host)
        bridge.publish(200, #"{"healthy":true,"queue":1}"#, at: "/status")
        bridge.publish(
            200,
            #"{"id":"s1","title":"t","messages":[],"queue":[\#(itemJSON)],"queuePaused":false}"#,
            etag: "\"v1\"", at: "/sessions/s1")
        let backend = backend(host: host)
        let first = try await backend.transcript(for: "s1")
        #expect(first.queue?.items.map(\.id) == ["q1"])

        bridge.publish(200, #"{"queue":[],"paused":true}"#, at: "/sessions/s1/queue")
        let second = try await backend.transcript(for: "s1")

        #expect(second.queue?.items.isEmpty == true)
        #expect(second.queue?.paused == true)
    }
}
