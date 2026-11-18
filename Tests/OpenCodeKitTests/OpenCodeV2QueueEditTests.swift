import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import OpenCodeKit

/// A stand-in opencode 2 server that keeps a session's inbox in memory, so what the backend reads
/// back is what its own requests left behind: a cancel takes an item out, and an admitted prompt
/// joins the tail exactly as the server would file it.
final class QueueEditServer: @unchecked Sendable {
    static let shared = QueueEditServer()

    struct Item {
        var id: String
        var payload: JSONValue
        var delivery: String?
        var created: Double

        /// One user prompt carrying words, and whatever else it was written with.
        static func user(
            _ id: String, _ text: String, delivery: String? = "steer", files: JSONValue? = nil
        ) -> Item {
            var payload: [String: JSONValue] = ["text": .string(text)]
            if let files { payload["files"] = files }
            return Item(id: id, payload: .object(payload), delivery: delivery, created: 0)
        }
    }

    private let lock = NSLock()
    private var items: [Item] = []
    private var clock: Double = 1_790_000_000_000
    private var cancelledIDs: [String] = []
    private var admittedBodies: [JSONValue] = []

    func reset(_ seeded: [Item]) {
        lock.withLock {
            items = seeded
            clock = 1_790_000_000_000
            cancelledIDs = []
            admittedBodies = []
        }
    }

    var cancelled: [String] { lock.withLock { cancelledIDs } }
    var admitted: [JSONValue] { lock.withLock { admittedBodies } }
    var held: [String] { lock.withLock { items.map(\.id) } }

    func answer(method: String, path: String, body: Data?) -> (Int, Data?, String) {
        lock.withLock {
            let segments = path.split(separator: "/").map(String.init)
            guard segments.count >= 4, segments[0] == "api", segments[1] == "session"
            else { return Self.notFound }
            switch (method, segments.count) {
            case ("GET", 4) where segments[3] == "inbox":
                return (200, Self.encode(inbox), Self.json)
            case ("DELETE", 5) where segments[3] == "inbox":
                cancelledIDs.append(segments[4])
                items.removeAll { $0.id == segments[4] }
                return (204, nil, Self.json)
            case ("POST", 4) where segments[3] == "prompt":
                guard let body, let value = try? JSONCoding.decoder.decode(JSONValue.self, from: body)
                else { return Self.badRequest }
                admittedBodies.append(value)
                guard let id = value["id"]?.stringValue, !items.contains(where: { $0.id == id })
                else { return (200, nil, Self.json) }
                clock += 13
                items.append(
                    Item(
                        id: id,
                        payload: .object([
                            "text": value["text"] ?? .string(""),
                            "files": value["files"] ?? .array([]),
                        ]),
                        delivery: value["delivery"]?.stringValue,
                        created: clock))
                return (200, nil, Self.json)
            default:
                return Self.notFound
            }
        }
    }

    private var inbox: JSONValue {
        .object([
            "data": .array(
                items.map { item in
                    var row: [String: JSONValue] = [
                        "id": .string(item.id),
                        "type": .string("user"),
                        "payload": item.payload,
                        "time": .object(["created": .number(item.created)]),
                    ]
                    if let delivery = item.delivery { row["delivery"] = .string(delivery) }
                    return .object(row)
                })
        ])
    }

    private static let json = "application/json"
    private static let notFound = (404, Data(#"{"_tag":"SessionNotFoundError"}"#.utf8), "application/json")
    private static let badRequest = (400, Data(#"{"_tag":"InvalidRequestError"}"#.utf8), "application/json")

    private static func encode(_ value: JSONValue) -> Data? {
        try? JSONCoding.encoder.encode(value)
    }
}

final class QueueEditServerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let (status, body, contentType) = QueueEditServer.shared.answer(
            method: request.httpMethod ?? "GET", path: url.path, body: Self.body(of: request))
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A URLSession hands a body to its protocol as a stream rather than as `httpBody`, and the
    /// stream can be read once, here, before the fake answers.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

@Suite(.serialized) struct OpenCodeV2QueueEditTests {
    private static let sessionID = "ses_1"

    private static func backend() -> OpenCodeV2Backend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QueueEditServerProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://inbox-oc2.test:4096")!)
        return OpenCodeV2Backend(client: OpenCodeV2Client(config: config, http: http))
    }

    private static func seed(_ items: [QueueEditServer.Item]) {
        QueueEditServer.shared.reset(items)
    }

    @Test func theBackendSaysItsQueueCanBeEdited() {
        #expect(Self.backend().capabilities.supportsQueueEdit)
    }

    @Test func cancellingTakesThePromptOutAndAnswersTheQueue() async throws {
        Self.seed([.user("msg_1", "one"), .user("msg_2", "two"), .user("msg_3", "three")])
        let snapshot = try await Self.backend().cancelQueued(
            sessionID: Self.sessionID, id: "msg_2")
        #expect(snapshot.items.map(\.id) == ["msg_1", "msg_3"])
        #expect(QueueEditServer.shared.cancelled == ["msg_2"])
        #expect(QueueEditServer.shared.held == ["msg_1", "msg_3"])
    }

    @Test func cancellingWhatHasStartedSaysSoAndAsksNothingOfTheServer() async {
        Self.seed([.user("msg_1", "one")])
        let backend = Self.backend()
        await #expect(throws: QueueError.alreadyStarted) {
            try await backend.cancelQueued(sessionID: Self.sessionID, id: "msg_2")
        }
        #expect(QueueEditServer.shared.cancelled.isEmpty)
        #expect(QueueEditServer.shared.held == ["msg_1"])
    }

    @Test func editingRewritesThePromptInItsPlaceAndLeavesTheRestWaiting() async throws {
        Self.seed([
            .user("msg_1", "one"),
            .user(
                "msg_2", "two", delivery: "queue",
                files: .array([
                    .object([
                        "data": .string("AAAA"), "mime": .string("image/png"),
                        "name": .string("/tmp/a.png"),
                    ])
                ])),
            .user("msg_3", "three"),
        ])
        let snapshot = try await Self.backend().editQueued(
            sessionID: Self.sessionID, id: "msg_2",
            edit: QueuedPromptEdit(text: "then lint it"))

        #expect(snapshot.items.map(\.id) == ["msg_1", "msg_2", "msg_3"])
        #expect(snapshot.items.map(\.text) == ["one", "then lint it", "three"])
        #expect(snapshot.items[1].attachments.map(\.filename) == ["a.png"])
        #expect(QueueEditServer.shared.cancelled == ["msg_2", "msg_3"])

        let admitted = QueueEditServer.shared.admitted
        #expect(admitted.count == 2)
        #expect(admitted[0]["id"]?.stringValue == "msg_2")
        #expect(admitted[0]["text"]?.stringValue == "then lint it")
        #expect(admitted[0]["delivery"]?.stringValue == "queue")
        #expect(admitted[0]["resume"]?.boolValue == false)
        #expect(
            admitted[0]["files"]
                == .array([
                    .object([
                        "data": .string("AAAA"), "mime": .string("image/png"),
                        "name": .string("/tmp/a.png"),
                    ])
                ]))
        #expect(admitted[1]["id"]?.stringValue == "msg_3")
        #expect(admitted[1]["text"]?.stringValue == "three")
    }

    @Test func editingWhatHasStartedSaysSoAndLeavesTheQueueAlone() async {
        Self.seed([.user("msg_1", "one")])
        let backend = Self.backend()
        await #expect(throws: QueueError.alreadyStarted) {
            try await backend.editQueued(
                sessionID: Self.sessionID, id: "msg_9", edit: QueuedPromptEdit(text: "gone"))
        }
        #expect(QueueEditServer.shared.cancelled.isEmpty)
        #expect(QueueEditServer.shared.admitted.isEmpty)
        #expect(QueueEditServer.shared.held == ["msg_1"])
    }
}
