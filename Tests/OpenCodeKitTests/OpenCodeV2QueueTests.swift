import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import OpenCodeKit

private func decode(_ json: String, decoder: inout OpenCodeV2EventDecoder) -> [BackendEvent] {
    decoder.decode(SSEvent(id: nil, type: nil, data: json))
}

private func enqueued(
    _ id: String, _ text: String, at created: Int, type: String = "user",
    files: String = "[]", session: String = "ses_S"
) -> String {
    #"{"type":"session.inbox.enqueued","created":\#(created),"data":{"inboxID":"\#(id)","sessionID":"\#(session)","item":{"type":"\#(type)","payload":{"text":"\#(text)","files":\#(files)},"delivery":"queue"}}}"#
}

private func delivered(_ id: String, at created: Int) -> String {
    #"{"type":"session.inbox.delivered","created":\#(created),"data":{"sessionID":"ses_S","inboxID":"\#(id)"}}"#
}

private func cancelled(_ id: String, at created: Int) -> String {
    #"{"type":"session.inbox.cancelled","created":\#(created),"data":{"sessionID":"ses_S","inboxID":"\#(id)"}}"#
}

private let executionStarted =
    #"{"id":"evt_1","type":"session.execution.started","created":1,"data":{"sessionID":"ses_S"}}"#
private let executionSucceeded =
    #"{"id":"evt_2","type":"session.execution.succeeded","created":9,"data":{"sessionID":"ses_S"}}"#

private func queue(in events: [BackendEvent]) -> QueueSnapshot? {
    for case .queue(let snapshot) in events { return snapshot }
    return nil
}

@Suite struct OpenCodeV2InboxQueueTests {
    @Test func aPromptEnqueuedBehindARunningTurnIsAnnouncedWithWhatItCarries() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")
        _ = decode(executionStarted, decoder: &decoder)

        let events = decode(
            enqueued(
                "msg_1", "then lint it", at: 1_790_181_060_112,
                files: #"[{"data":"AAAA","mime":"image/png","name":"/tmp/a.png"}]"#),
            decoder: &decoder)

        let snapshot = queue(in: events)
        #expect(events.count == 1)
        #expect(snapshot?.paused == false)
        let first = snapshot?.items.first
        #expect(first?.id == "msg_1")
        #expect(first?.text == "then lint it")
        #expect(first?.kind == .prompt)
        #expect(first?.createdAt == Date(timeIntervalSince1970: 1_790_181_060.112))
        #expect(first?.attachments == [QueuedAttachment(mime: "image/png", filename: "a.png", size: 3)])
    }

    @Test func theQueueIsAnnouncedWholeInArrivalOrderAndShrinksAsItemsAreTaken() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")
        _ = decode(executionStarted, decoder: &decoder)
        _ = decode(enqueued("msg_1", "one", at: 2), decoder: &decoder)
        let both = decode(enqueued("msg_2", "two", at: 3), decoder: &decoder)
        #expect(queue(in: both)?.items.map(\.id) == ["msg_1", "msg_2"])

        let taken = decode(delivered("msg_1", at: 4), decoder: &decoder)
        guard case .messageUpserted(let message, _)? = taken.first else {
            Issue.record("expected the delivered prompt as a message, got \(taken)")
            return
        }
        #expect(message.id == "msg_1")
        #expect(queue(in: taken)?.items.map(\.id) == ["msg_2"])

        let cancelledOne = decode(cancelled("msg_2", at: 5), decoder: &decoder)
        #expect(queue(in: cancelledOne)?.items.isEmpty == true)
        #expect(cancelledOne.count == 1)
    }

    @Test func aPromptEnqueuedWithNothingRunningIsNeverShownAsQueued() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")
        _ = decode(executionStarted, decoder: &decoder)
        _ = decode(executionSucceeded, decoder: &decoder)

        let waiting = decode(enqueued("msg_1", "right away", at: 10), decoder: &decoder)
        #expect(waiting.isEmpty)

        let taken = decode(delivered("msg_1", at: 11), decoder: &decoder)
        #expect(taken.count == 1)
        guard case .messageUpserted? = taken.first else {
            Issue.record("expected only the message, got \(taken)")
            return
        }
    }

    @Test func aLineWrittenForTheModelAloneIsNotAQueuedPrompt() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")
        _ = decode(executionStarted, decoder: &decoder)

        let events = decode(enqueued("msg_R", "restarted", at: 2, type: "synthetic"), decoder: &decoder)

        #expect(events.isEmpty)
    }

    @Test func anotherSessionsInboxIsSilent() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")
        _ = decode(executionStarted, decoder: &decoder)

        let events = decode(
            enqueued("msg_1", "elsewhere", at: 2, session: "ses_OTHER"), decoder: &decoder)

        #expect(events.isEmpty)
    }

    @Test func theServersInboxAtConnectionIsTheQueueAndItsPromptsCanStillBeDelivered() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")
        let inbox = [
            OC2InboxItem(
                id: "msg_1", type: "user", payload: .object(["text": .string("already waiting")]),
                time: OC2MessageTime(created: 5_000, streamed: nil, completed: nil)),
            OC2InboxItem(
                id: "msg_R", type: "synthetic", payload: .object(["text": .string("note")])),
        ]

        let seeded = decoder.seed(inbox)
        #expect(queue(in: seeded)?.items.map(\.id) == ["msg_1"])
        #expect(queue(in: seeded)?.items.first?.createdAt == Date(timeIntervalSince1970: 5))

        let taken = decode(delivered("msg_1", at: 6), decoder: &decoder)
        guard case .messageUpserted(let message, _)? = taken.first else {
            Issue.record("expected the prompt the server held as a message, got \(taken)")
            return
        }
        #expect(message.parts.first?.text == "already waiting")
        #expect(queue(in: taken)?.items.isEmpty == true)
    }

    @Test func anEmptyInboxIsStillAnnouncedAtConnectionBecauseItIsTheServersOwnAccount() {
        var decoder = OpenCodeV2EventDecoder(sessionID: "ses_S")

        #expect(queue(in: decoder.seed([]))?.isEmpty == true)
    }

    @Test func anInboxItemWithATimeInAShapeNobodyKnowsStillReads() throws {
        let json = #"[{"id":"msg_1","type":"user","payload":{"text":"hi"},"time":"yesterday"}]"#
        let items = try JSONCoding.decoder.decode([OC2InboxItem].self, from: Data(json.utf8))

        #expect(items.count == 1)
        #expect(OpenCodeV2Mapping.queue(items).items.first?.createdAt == .distantPast)
    }
}

/// A stand-in opencode 2 server of this suite's own, so that its answers are never reset from
/// under another suite that is running beside it.
final class InboxServerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let (status, body) = InboxServer.shared.answer(
            path: url.path, method: request.httpMethod ?? "GET")
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class InboxServer: @unchecked Sendable {
    static let shared = InboxServer()

    private let lock = NSLock()
    private var answers: [String: (Int, Data?)] = [:]
    private var hits: [String: Int] = [:]

    func reset() {
        lock.withLock {
            answers.removeAll()
            hits.removeAll()
        }
    }

    func publish(_ status: Int, _ body: String?, method: String = "GET", at path: String) {
        lock.withLock { answers["\(method) \(path)"] = (status, body.map { Data($0.utf8) }) }
    }

    func answer(path: String, method: String) -> (Int, Data?) {
        lock.withLock {
            hits["\(method) \(path)", default: 0] += 1
            return answers["\(method) \(path)"] ?? (404, nil)
        }
    }

    func hitCount(method: String, path: String) -> Int {
        lock.withLock { hits["\(method) \(path)"] ?? 0 }
    }
}

@Suite(.serialized) struct OpenCodeV2QueueBackendTests {
    private static func backend() -> OpenCodeV2Backend {
        InboxServer.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InboxServerProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://queue-oc2.test:4096")!)
        return OpenCodeV2Backend(client: OpenCodeV2Client(config: config, http: http))
    }

    private static let inboxOne =
        #"{"data":[{"id":"msg_1","type":"user","payload":{"text":"waiting"}},{"id":"msg_R","type":"synthetic","payload":{"text":"note"}}]}"#

    private static func publishSession(running: Bool, inbox: String) {
        InboxServer.shared.publish(200, #"{"data":[]}"#, at: "/api/session/ses_1/message")
        InboxServer.shared.publish(
            200, running ? #"{"data":{"ses_1":{"type":"running"}}}"# : #"{"data":{}}"#,
            at: "/api/session/active")
        InboxServer.shared.publish(200, inbox, at: "/api/session/ses_1/inbox")
        InboxServer.shared.publish(200, "{}", method: "POST", at: "/api/session/ses_1/prompt")
    }

    @Test func version2OffersAServerQueueWithoutEditing() {
        let capabilities = Self.backend().capabilities

        #expect(capabilities.supportsServerQueue)
        #expect(!capabilities.supportsQueueEdit)
    }

    @Test func version1KeepsItsQueueOnTheDevice() async {
        #expect(!OpenCodeV1Backend.baseline.supportsServerQueue)
        #expect(!OpenCodeV1Backend.baseline.supportsQueueEdit)
    }

    @Test func aReadCarriesTheInboxAsTheQueueAndLeavesTheModelsLinesOut() async throws {
        let backend = Self.backend()
        Self.publishSession(running: true, inbox: Self.inboxOne)

        let snapshot = try await backend.transcript(for: "ses_1")

        #expect(snapshot.queue?.items.map(\.id) == ["msg_1"])
        #expect(snapshot.queue?.items.first?.text == "waiting")
        #expect(snapshot.queue?.paused == false)
    }

    @Test func aServerWhoseInboxCannotBeReadSaysNothingAboutTheQueue() async throws {
        let backend = Self.backend()
        Self.publishSession(running: false, inbox: Self.inboxOne)
        InboxServer.shared.publish(500, "boom", at: "/api/session/ses_1/inbox")

        let snapshot = try await backend.transcript(for: "ses_1")

        #expect(snapshot.queue == nil)
    }

    @Test func aPromptSentWhileATurnRunsComesBackQueued() async throws {
        let backend = Self.backend()
        Self.publishSession(running: true, inbox: Self.inboxOne)

        let result = try await backend.enqueue(
            sessionID: "ses_1", prompt: EnqueuePrompt(prompt: SendPrompt(text: "later")))

        #expect(!result.started)
        #expect(result.queue.items.map(\.id) == ["msg_1"])
        #expect(InboxServer.shared.hitCount(method: "POST", path: "/api/session/ses_1/prompt") == 1)
    }

    @Test func aPromptSentToAnIdleSessionStartsAtOnceAndLeavesTheQueueAsItWas() async throws {
        let backend = Self.backend()
        Self.publishSession(running: false, inbox: Self.inboxOne)

        let result = try await backend.enqueue(
            sessionID: "ses_1", prompt: EnqueuePrompt(prompt: SendPrompt(text: "now")))

        #expect(result.started)
        #expect(result.queue.items.map(\.id) == ["msg_1"])
    }

    @Test func cancellingAndEditingAreNotOfferedBecauseTheServerHasNoRouteForThem() async {
        let backend = Self.backend()

        await #expect(throws: AgentError.unsupported("queue")) {
            try await backend.cancelQueued(sessionID: "ses_1", id: "msg_1")
        }
        await #expect(throws: AgentError.unsupported("queue")) {
            try await backend.editQueued(
                sessionID: "ses_1", id: "msg_1", edit: QueuedPromptEdit(text: "x"))
        }
        await #expect(throws: AgentError.unsupported("queue")) {
            try await backend.resumeQueue(sessionID: "ses_1")
        }
    }

    @Test func aQueuedCommandStaysOnTheDevice() async {
        let backend = Self.backend()
        Self.publishSession(running: true, inbox: Self.inboxOne)

        await #expect(throws: AgentError.unsupported("queued command")) {
            try await backend.enqueue(
                sessionID: "ses_1",
                prompt: EnqueuePrompt(kind: .command, prompt: SendPrompt(text: "/review")))
        }
    }

    @Test func theFacadeForwardsTheQueueToTheGenerationItResolved() async throws {
        let v2 = Self.backend()
        Self.publishSession(running: true, inbox: Self.inboxOne)
        let facade = OpenCodeBackend(resolve: { v2 })
        #expect(!facade.capabilities.supportsServerQueue)

        let result = try await facade.enqueue(
            sessionID: "ses_1", prompt: EnqueuePrompt(prompt: SendPrompt(text: "later")))

        #expect(!result.started)
        #expect(result.queue.items.map(\.id) == ["msg_1"])
        #expect(facade.capabilities.supportsServerQueue)
    }
}
