import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

@Suite struct MockBackendTurnWaitTests {
    @Test func unsupportedMockOffersNoRequest() async throws {
        let backend = MockBackend(turnWaitSupport: .unavailable(.generation))
        #expect(await backend.turnWaitSupport() == .unavailable(.generation))
        #expect(try await backend.turnWaitRequest(for: "mock") == nil)
    }

    @Test func supportedMockOffersARequestCarryingTheSessionID() async throws {
        let backend = MockBackend()
        #expect(await backend.turnWaitSupport() == .supported)
        let request = try await backend.turnWaitRequest(for: "mock")
        #expect(request?.request.url?.absoluteString.contains("mock") == true)
    }

    /// A script of several answers plays out in call order, one per `turnWaitResult` call, so a
    /// test can drive a session through running → running → ended without a real server.
    @Test func aScriptedSessionPlaysItsAnswersInOrder() async throws {
        let ended = TurnWaitResult(state: .ended, waited: true, ending: .finished, toolCount: 2)
        let backend = MockBackend(
            turnWaitResults: [
                "mock": [
                    TurnWaitResult(state: .running, waited: false),
                    TurnWaitResult(state: .running, waited: false),
                    ended,
                ]
            ])
        let states = try await [
            backend.turnWaitResult(status: 200, headers: [:], body: Data(), sessionID: "mock").state,
            backend.turnWaitResult(status: 200, headers: [:], body: Data(), sessionID: "mock").state,
            backend.turnWaitResult(status: 200, headers: [:], body: Data(), sessionID: "mock").state,
        ]
        #expect(states == [.running, .running, .ended])
        let last = try await backend.turnWaitResult(
            status: 200, headers: [:], body: Data(), sessionID: "mock")
        #expect(last == ended)
    }

    @Test func aSessionWithNoScriptThrows() async {
        let backend = MockBackend()
        await #expect(throws: (any Error).self) {
            try await backend.turnWaitResult(
                status: 200, headers: [:], body: Data(), sessionID: "unscripted")
        }
    }

    @Test func theReceiptIsWhateverWasScripted() async throws {
        let backend = MockBackend(pushReceipt: DevicePushRegistration.Receipt(delivers: true))
        let receipt = try await backend.registerDeviceTokenReceipt(
            DevicePushRegistration(token: "t", environment: "production"))
        #expect(receipt.delivers == true)
    }
}
