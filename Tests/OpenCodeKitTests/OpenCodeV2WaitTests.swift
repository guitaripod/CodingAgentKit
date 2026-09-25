import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import AgentCore
@testable import OpenCodeKit

private func records(_ json: String) throws -> [OC2Message] {
    try JSONCoding.decoder.decode([OC2Message].self, from: Data(json.utf8))
}

/// The same captured turn `OpenCodeV2MappingTests` reads: a prompt, one step that ran a shell
/// tool, the step that answered, and the idle marker.
private let finishedTurn = #"""
    [
      {"id":"msg_U","time":{"created":1789999433515},"text":"Run the shell command `ls -la /tmp/oc2a` and then tell me in one sentence what you saw.","type":"user"},
      {"id":"msg_A1","time":{"created":1789999433524,"streamed":1789999437422,"completed":1789999437453},"type":"assistant","agent":"build","model":{"id":"muse","providerID":"opencode"},"content":[{"type":"text","text":"Running that listing now.","state":{"itemId":"rs_2"}},{"type":"tool","id":"call_1","name":"shell","executed":true,"state":{"status":"completed","input":{"command":"ls -la /tmp/oc2a"},"content":[{"type":"text","text":"total 0"}],"metadata":{"shellID":"sh_1"}},"time":{"created":1789999433800,"ran":1789999437100,"completed":1789999437400}}],"finish":"tool-calls","cost":0,"tokens":{"input":7698,"output":72,"cache":{"read":0,"write":0}}},
      {"id":"msg_A2","time":{"created":1789999437463,"streamed":1789999438975,"completed":1789999438977},"type":"assistant","agent":"build","model":{"id":"muse","providerID":"opencode"},"content":[{"type":"text","text":"I saw that `/tmp/oc2a` is an empty directory.","state":{}}],"finish":"stop","cost":0,"tokens":{"input":218,"output":32,"cache":{"read":7665,"write":0}}},
      {"id":"msg_I","time":{"created":1789999438981},"type":"idle","outcome":"succeeded"}
    ]
    """#

/// A turn the provider refused mid-stream: the assistant record closes with an error and no
/// content at all.
private let failedTurn = #"""
    [
      {"id":"msg_U","time":{"created":1000},"text":"Do the thing","type":"user"},
      {"id":"msg_A1","time":{"created":1010,"completed":1020},"type":"assistant","agent":"build","content":[],"error":{"name":"ProviderRefused","message":"blocked"}}
    ]
    """#

/// A turn that finished with no words, no tool call and no error — the answerless outcome.
private let answerlessTurn = #"""
    [
      {"id":"msg_U","time":{"created":1000},"text":"Do the thing","type":"user"},
      {"id":"msg_A1","time":{"created":1010,"completed":1020},"type":"assistant","agent":"build","content":[],"finish":"stop"}
    ]
    """#

/// A turn the person stopped mid-stream: partial, unremarkable content and no error on the last
/// assistant message, but the idle record's own outcome says otherwise.
private let interruptedTurn = #"""
    [
      {"id":"msg_U","time":{"created":1000},"text":"Do the thing","type":"user"},
      {"id":"msg_A1","time":{"created":1010,"completed":1020},"type":"assistant","agent":"build","content":[{"type":"text","text":"Working on it"}],"finish":"stop"},
      {"id":"msg_I","time":{"created":1030},"type":"idle","outcome":"interrupted"}
    ]
    """#

/// A turn the idle record itself says failed, even though the last assistant message carries no
/// `error` of its own — the session/idle-level failure the last message never recorded.
private let idleFailedTurn = #"""
    [
      {"id":"msg_U","time":{"created":1000},"text":"Do the thing","type":"user"},
      {"id":"msg_A1","time":{"created":1010,"completed":1020},"type":"assistant","agent":"build","content":[{"type":"text","text":"Working on it"}],"finish":"stop"},
      {"id":"msg_I","time":{"created":1030},"type":"idle","outcome":"failed"}
    ]
    """#

@Suite struct OpenCodeV2WaitOutcomeTests {
    @Test func aFinishedTurnCountsItsToolsSinceTheLastPrompt() throws {
        let raw = try records(finishedTurn)
        let outcome = try #require(OpenCodeV2Mapping.waitOutcome(raw: raw, tail: OpenCodeV2Mapping.transcript(raw)))
        #expect(outcome.ending == .finished)
        #expect(outcome.toolCount == 1)
        #expect(outcome.lastMessageID == "msg_A2")
    }

    @Test func aProviderErrorIsFailed() throws {
        let raw = try records(failedTurn)
        let outcome = try #require(OpenCodeV2Mapping.waitOutcome(raw: raw, tail: OpenCodeV2Mapping.transcript(raw)))
        #expect(outcome.ending == .failed)
        #expect(outcome.lastMessageID == "msg_A1")
    }

    @Test func aWordlessToollessTurnIsAnswerless() throws {
        let raw = try records(answerlessTurn)
        let outcome = try #require(OpenCodeV2Mapping.waitOutcome(raw: raw, tail: OpenCodeV2Mapping.transcript(raw)))
        #expect(outcome.ending == .answerless)
    }

    /// The idle record's own verdict outranks the last assistant message's unremarkable shape —
    /// exactly the case `halted()` deliberately leaves looking like an ordinary answer.
    @Test func anIdleOutcomeOfInterruptedIsCancelledEvenWithOrdinaryContent() throws {
        let raw = try records(interruptedTurn)
        let outcome = try #require(OpenCodeV2Mapping.waitOutcome(raw: raw, tail: OpenCodeV2Mapping.transcript(raw)))
        #expect(outcome.ending == .cancelled)
    }

    /// The idle record can say failed even when the last assistant message carries no `error` at
    /// all — a session-level failure the message itself never recorded.
    @Test func anIdleOutcomeOfFailedIsFailedEvenWithNoMessageError() throws {
        let raw = try records(idleFailedTurn)
        let outcome = try #require(OpenCodeV2Mapping.waitOutcome(raw: raw, tail: OpenCodeV2Mapping.transcript(raw)))
        #expect(outcome.ending == .failed)
    }

    /// A tail with no assistant record at all — a very tool-heavy turn could in principle push
    /// its own answer past a short tail — leaves the caller to fall back to a bare `finished`.
    @Test func aTailWithNoAssistantMessageIsNil() {
        let tail = [
            ChatMessage(id: "msg_U", role: .user, agentType: .openCode, createdAt: Date())
        ]
        #expect(OpenCodeV2Mapping.waitOutcome(raw: [], tail: tail) == nil)
    }

    /// Only tool parts after the most recent user message count — a tool call from an earlier
    /// turn still sitting in the tail must not inflate this turn's count.
    @Test func toolsBeforeTheLastPromptDoNotCount() {
        let earlierTool = ChatMessage(
            id: "msg_A0", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "msg_A0/tool", kind: .tool(ToolCall(id: "c0", name: "shell", status: .completed)))],
            createdAt: Date(), completedAt: Date())
        let prompt = ChatMessage(id: "msg_U", role: .user, agentType: .openCode, createdAt: Date())
        let answer = ChatMessage(
            id: "msg_A1", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "msg_A1/text", kind: .text("done"))],
            createdAt: Date(), completedAt: Date())
        let outcome = try? #require(
            OpenCodeV2Mapping.waitOutcome(raw: [], tail: [earlierTool, prompt, answer]))
        #expect(outcome?.toolCount == 0)
    }
}

@Suite struct OpenCodeV2ProbeClassificationTests {
    private func raw(status: Int, headers: [String: String] = [:], body: String) -> HTTPClient.RawResponse {
        HTTPClient.RawResponse(status: status, headers: headers, data: Data(body.utf8))
    }

    @Test func aTypedNotFoundMeansTheRouteExists() {
        let response = raw(
            status: 404, headers: ["Content-Type": "application/json"],
            body: #"{"_tag":"SessionNotFoundError","sessionID":"x","message":"Session not found: x"}"#)
        #expect(OpenCodeV2Backend.classifyWaitProbe(response) == .supported)
    }

    @Test func anUnmatchedRouteAnsweringTheWebUIIsUnsupported() {
        let response = raw(
            status: 200, headers: ["Content-Type": "text/html"], body: "<html></html>")
        #expect(OpenCodeV2Backend.classifyWaitProbe(response) == .serverTooOld)
    }

    @Test func aFourOhFourWithHTMLIsUnsupported() {
        let response = raw(
            status: 404, headers: ["Content-Type": "text/html"], body: "<html></html>")
        #expect(OpenCodeV2Backend.classifyWaitProbe(response) == .serverTooOld)
    }

    @Test func aFourOhFourWithUnparsableBodyIsUnsupported() {
        let response = raw(status: 404, headers: [:], body: "not json")
        #expect(OpenCodeV2Backend.classifyWaitProbe(response) == .serverTooOld)
    }

    @Test func anyOtherStatusIsUnsupported() {
        let response = raw(status: 400, headers: [:], body: #"{"_tag":"InvalidRequestError"}"#)
        #expect(OpenCodeV2Backend.classifyWaitProbe(response) == .serverTooOld)
    }
}
