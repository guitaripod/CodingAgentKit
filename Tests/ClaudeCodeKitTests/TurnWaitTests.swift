import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

/// A stand-in bridge that answers whatever `WaitBridge.shared` has been told to for the path
/// asked — `/status`, the wait route itself, or the device-push route — so a test can drive each
/// path's status and body independently of the others.
final class WaitBridgeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let (status, body) = WaitBridge.shared.answer(path: url.path)
        guard status >= 0 else {
            client.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WaitBridge: @unchecked Sendable {
    static let shared = WaitBridge()

    private let lock = NSLock()
    private var answers: [String: (Int, Data?)] = [:]
    private var hits: [String: Int] = [:]

    func publish(_ status: Int, _ body: String?, at path: String) {
        lock.withLock { answers[path] = (status, body.map { Data($0.utf8) }) }
    }

    /// A negative status is this stub's own signal to fail the connection outright, standing in
    /// for a dropped tailnet hop rather than any answer a real bridge would give.
    func publishTransportFailure(at path: String) {
        lock.withLock { answers[path] = (-1, nil) }
    }

    func answer(path: String) -> (Int, Data?) {
        lock.withLock {
            hits[path, default: 0] += 1
            return answers[path] ?? (404, nil)
        }
    }

    func hitCount(_ path: String) -> Int {
        lock.withLock { hits[path] ?? 0 }
    }
}

@Suite(.serialized) struct ClaudeCodeTurnWaitTests {
    private static func backend() -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://waiting.test:4098")!)
        return ClaudeCodeBackend(config: config, agentType: .claudeCode, http: http)
    }

    @Test func aBridgeThatNamesTheRouteVersionSupportsWaiting() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"healthy":true,"turnWait":1}"#, at: "/status")
        let backend = Self.backend()
        #expect(await backend.turnWaitSupport() == .supported)
    }

    @Test func aBridgeThatOmitsTheFieldIsTooOld() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"healthy":true}"#, at: "/status")
        let backend = Self.backend()
        #expect(await backend.turnWaitSupport() == .serverTooOld)
    }

    /// A dropped connection says nothing about the bridge's age and must never be latched as
    /// "too old" — it is asked again next time instead.
    @Test func aDroppedConnectionIsUndetermined() async throws {
        let bridge = WaitBridge.shared
        bridge.publishTransportFailure(at: "/status")
        let backend = Self.backend()
        #expect(await backend.turnWaitSupport() == .undetermined)
    }

    /// A definite answer is held rather than asked for again on every call.
    @Test func aDefiniteAnswerIsCached() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"healthy":true,"turnWait":1}"#, at: "/status")
        let backend = Self.backend()
        let before = bridge.hitCount("/status")

        let first = await backend.turnWaitSupport()
        let second = await backend.turnWaitSupport()

        #expect(first == .supported)
        #expect(second == .supported)
        #expect(bridge.hitCount("/status") - before == 1)
    }

    /// An undetermined answer is never held — the very next call asks again, and once the bridge
    /// answers for real that answer is what gets cached.
    @Test func anUndeterminedAnswerIsNeverCached() async throws {
        let bridge = WaitBridge.shared
        bridge.publishTransportFailure(at: "/status")
        let backend = Self.backend()
        let before = bridge.hitCount("/status")
        #expect(await backend.turnWaitSupport() == .undetermined)

        bridge.publish(200, #"{"healthy":true,"turnWait":1}"#, at: "/status")
        #expect(await backend.turnWaitSupport() == .supported)
        #expect(bridge.hitCount("/status") - before == 2)
    }

    @Test func aRequestIsOfferedOnlyWhenSupported() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"healthy":true,"turnWait":1}"#, at: "/status")
        let backend = Self.backend()
        let request = try await backend.turnWaitRequest(for: "c1")
        #expect(request?.uploadsEmptyBody == false)
        #expect(request?.request.url?.path == "/sessions/c1/wait")
        #expect(request?.request.httpMethod == "GET")
    }

    @Test func aTooOldBridgeOffersNoRequest() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"healthy":true}"#, at: "/status")
        let backend = Self.backend()
        #expect(try await backend.turnWaitRequest(for: "c1") == nil)
    }

    @Test func aHeartbeatPrefixedBodyDecodes() async throws {
        let backend = Self.backend()
        let result = try await backend.turnWaitResult(
            status: 200, headers: [:],
            body: Data("\n\n{\"state\":\"ended\",\"waited\":true,\"ending\":\"finished\"}".utf8),
            sessionID: "c1")
        #expect(result.state == .ended)
        #expect(result.ending == .finished)
    }

    @Test func aNonSuccessStatusThrows() async {
        let backend = Self.backend()
        await #expect(throws: (any Error).self) {
            try await backend.turnWaitResult(
                status: 500, headers: [:], body: Data("oops".utf8), sessionID: "c1")
        }
    }

    @Test func anUnparsableBodyThrows() async {
        let backend = Self.backend()
        await #expect(throws: (any Error).self) {
            try await backend.turnWaitResult(
                status: 200, headers: [:], body: Data("not json".utf8), sessionID: "c1")
        }
    }

    @Test func aReceiptCarriesDeliversWhenTheBridgeSaysSo() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"ok":true,"delivers":true}"#, at: "/push/device")
        let backend = Self.backend()
        let receipt = try await backend.registerDeviceTokenReceipt(
            DevicePushRegistration(token: "t", environment: "production"))
        #expect(receipt.delivers == true)
    }

    @Test func anOlderBridgeThatSaysNothingLeavesTheReceiptUnknown() async throws {
        let bridge = WaitBridge.shared
        bridge.publish(200, #"{"ok":true}"#, at: "/push/device")
        let backend = Self.backend()
        let receipt = try await backend.registerDeviceTokenReceipt(
            DevicePushRegistration(token: "t", environment: "production"))
        #expect(receipt.delivers == nil)
    }
}
