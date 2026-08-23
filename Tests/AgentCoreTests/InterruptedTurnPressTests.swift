import Foundation
import Testing

@testable import AgentCore

/// A server whose interruption record and whose answer to a press are both scripted, so every way
/// a press can be refused is exercised without stopping a real agent mid-answer.
private final class PressBackend: CodingAgentBackend, @unchecked Sendable {
    let agentType: AgentType = .claudeCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: false, supportsModelSelection: false,
        supportsAttachments: false, reportsInterruptions: true)

    private let lock = NSLock()
    private var record: TurnInterruption?
    private var refusal: AgentError?
    private var afterPress: TurnInterruption??
    private(set) var sent: [String] = []
    private(set) var presses = 0
    private var readable = true

    init(holding record: TurnInterruption?) {
        self.record = record
    }

    /// What the server refuses the next press with, and what it holds by the time the refetch that
    /// refusal triggers arrives — which is the whole point of a conflict.
    func script(refusal: AgentError?, thenHolding held: TurnInterruption?) {
        lock.lock()
        defer { lock.unlock() }
        self.refusal = refusal
        self.afterPress = .some(held)
    }

    func health() async throws -> ServerHealth { ServerHealth(healthy: true) }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        AgentSession(
            id: "s", agentType: agentType, title: title ?? "s",
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        note(sent: prompt.text)
    }

    func interruption(for sessionID: String) async throws -> TurnInterruption? {
        try held()
    }

    func resumeInterruption(sessionID: String) async throws {
        try answerPress(forgetting: false)
    }

    func dismissInterruption(sessionID: String) async throws {
        try answerPress(forgetting: true)
    }

    private func note(sent text: String) {
        lock.lock()
        defer { lock.unlock() }
        sent.append(text)
    }

    /// A server that stops answering the read the press triggers, which is the only way a client
    /// can be left with no account of what it just did.
    func refuseReads() {
        lock.lock()
        defer { lock.unlock() }
        readable = false
    }

    private func held() throws -> TurnInterruption? {
        lock.lock()
        defer { lock.unlock() }
        guard readable else { throw AgentError.connection("unreachable") }
        return record
    }

    private func answerPress(forgetting: Bool) throws {
        lock.lock()
        presses += 1
        let refusal = self.refusal
        if let held = afterPress { record = held }
        if forgetting, refusal == nil { record = nil }
        lock.unlock()
        if let refusal { throw refusal }
    }
}

/// What a press on the cut-off card does when the server will not take it.
///
/// The failure this pins is the one a person met on a phone: a card whose press was refused, a red
/// line with none of the server's words in it, and the same stale card still standing afterwards to
/// be pressed again forever.
@Suite struct InterruptedTurnPressTests {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    private func cutOff(resumedAt: Date? = nil) -> TurnInterruption {
        TurnInterruption(
            turnID: "t1", prompt: "port the toggles", startedAt: started,
            detectedAt: started.addingTimeInterval(300), resumedAt: resumedAt)
    }

    private func standing(_ backend: PressBackend) async -> AgentConversation {
        let conversation = AgentConversation(backend: backend, sessionID: "s")
        try? await conversation.refresh()
        return conversation
    }

    private func conflict(_ reason: String, _ said: String) -> AgentError {
        .http(status: 409, body: "{\"error\":\"\(said)\",\"reason\":\"\(reason)\"}")
    }

    @Test func aConflictTakesTheStaleCardDownInsteadOfLeavingItToBePressedAgain() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        #expect(await conversation.state.interruption != nil)

        backend.script(
            refusal: conflict(
                "nothing_interrupted", "Nothing to pick up — no turn in this session was interrupted."),
            thenHolding: nil)
        await #expect(throws: AgentError.self) {
            try await conversation.resumeInterruptedTurn()
        }
        #expect(await conversation.state.interruption == nil)
    }

    @Test func aRefusalCarriesTheServersOwnSentenceRatherThanOneOfOurs() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(
            refusal: conflict(
                "nothing_interrupted", "Nothing to pick up — no turn in this session was interrupted."),
            thenHolding: nil)
        do {
            try await conversation.resumeInterruptedTurn()
            Issue.record("a refused press must throw")
        } catch let error as AgentError {
            guard case .http(let status, let body) = error else {
                Issue.record("a refusal keeps the server's answer")
                return
            }
            #expect(status == 409)
            #expect(body.contains("Nothing to pick up"))
            #expect(error.errorDescription?.contains("Nothing to pick up") == true)
        }
    }

    @Test func alreadyResumedCorrectsTheCardRatherThanRemovingIt() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(
            refusal: conflict("already_resumed", "That turn is already being picked back up."),
            thenHolding: cutOff(resumedAt: started.addingTimeInterval(600)))
        await #expect(throws: AgentError.self) {
            try await conversation.resumeInterruptedTurn()
        }
        #expect(await conversation.state.interruption?.resumedAt != nil)
    }

    @Test func anUnknownSessionIsAConflictRatherThanAMissingRoute() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(
            refusal: .http(
                status: 404, body: "{\"error\":\"not found\",\"reason\":\"unknown_session\"}"),
            thenHolding: nil)
        await #expect(throws: AgentError.self) {
            try await conversation.resumeInterruptedTurn()
        }
        #expect(backend.sent.isEmpty)
        #expect(await conversation.state.interruption == nil)
    }

    @Test func aBridgeWithoutTheRouteStillPicksTheTurnBackUp() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(refusal: .http(status: 404, body: "not found"), thenHolding: cutOff())
        try await conversation.resumeInterruptedTurn()
        #expect(backend.sent == ["port the toggles"])
        #expect(await conversation.state.interruption == nil)
    }

    @Test func anAcceptedPressLeavesTheCardStandingAndSayingSo() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(
            refusal: nil, thenHolding: cutOff(resumedAt: started.addingTimeInterval(600)))
        try await conversation.resumeInterruptedTurn()
        #expect(await conversation.state.interruption?.resumedAt != nil)
    }

    @Test func aServerThatCannotBeReReadStillStampsTheCardItJustAccepted() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(refusal: nil, thenHolding: nil)
        backend.refuseReads()
        try await conversation.resumeInterruptedTurn()
        #expect(await conversation.state.interruption?.resumedAt != nil)
    }

    @Test func aServerThatBrokeLeavesTheOfferExactlyWhereItWas() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(
            refusal: .http(status: 500, body: "{\"error\":\"the machine went away\"}"),
            thenHolding: cutOff())
        await #expect(throws: AgentError.self) {
            try await conversation.resumeInterruptedTurn()
        }
        #expect(backend.sent.isEmpty)
        #expect(await conversation.state.interruption != nil)
    }

    @Test func lettingGoOfARecordTheServerAlreadyDroppedIsNotAFailure() async throws {
        let backend = PressBackend(holding: cutOff())
        let conversation = await standing(backend)
        backend.script(
            refusal: conflict(
                "nothing_interrupted", "Nothing to let go — no turn in this session was interrupted."),
            thenHolding: nil)
        try await conversation.dismissInterruptedTurn()
        #expect(await conversation.state.interruption == nil)
    }
}
