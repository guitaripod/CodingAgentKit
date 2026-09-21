import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

private let sessionID = "ses_S"
private let messageID = "msg_A"

private func frame(_ json: String) -> SSEvent {
    SSEvent(id: nil, type: nil, data: json)
}

private func decode(_ json: String, decoder: inout OpenCodeV2EventDecoder) -> [BackendEvent] {
    decoder.decode(frame(json))
}

private func decode(_ json: String) -> [BackendEvent] {
    var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
    return decode(json, decoder: &decoder)
}

@Suite struct OpenCodeV2EventDecoderTests {
    @Test func theSocketProvingItselfIsAttachment() {
        let events = decode(#"{"id":"evt_1","type":"server.connected","data":{}}"#)
        guard case .attached? = events.first, events.count == 1 else {
            Issue.record("expected attached, got \(events)")
            return
        }
    }

    @Test func anotherSessionsFrameIsSilent() {
        let events = decode(
            #"{"type":"session.text.delta","created":1,"data":{"sessionID":"ses_OTHER","assistantMessageID":"msg_A","ordinal":0,"delta":"x"}}"#
        )
        #expect(events.isEmpty)
    }

    @Test func aStepOpensAStreamingAssistantMessageAndRunsTheTurn() {
        let events = decode(
            #"{"type":"session.step.started","created":1789999433600,"data":{"sessionID":"ses_S","agent":"build","model":{"id":"muse","providerID":"opencode","variant":"high"},"assistantMessageID":"msg_A","started":1789999433524}}"#
        )
        #expect(events.count == 2)
        guard case .messageUpserted(let message, let replaceParts)? = events.first else {
            Issue.record("expected messageUpserted, got \(events)")
            return
        }
        #expect(replaceParts == false)
        #expect(message.id == "msg_A")
        #expect(message.role == .assistant)
        #expect(message.isStreaming)
        #expect(message.modelID == "muse")
        #expect(message.providerID == "opencode")
        #expect(message.reasoningEffort == "high")
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_789_999_433.524))
        guard case .status(.running)? = events.last else {
            Issue.record("expected running, got \(events)")
            return
        }
    }

    @Test func proseIsAddressedByItsOrdinalAcrossStartDeltaAndEnd() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        let started = decode(
            #"{"type":"session.text.started","created":5,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","ordinal":1}}"#,
            decoder: &decoder)
        guard case .partUpserted(let owner, let part)? = started.first else {
            Issue.record("expected partUpserted, got \(started)")
            return
        }
        #expect(owner == "msg_A")
        #expect(part.id == OpenCodeV2Mapping.textPartID("msg_A", ordinal: 1))
        #expect(part.text == "")
        #expect(part.startedAt == Date(timeIntervalSince1970: 0.005))

        let delta = decode(
            #"{"type":"session.text.delta","created":6,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","ordinal":1,"delta":"Hel"}}"#,
            decoder: &decoder)
        guard case .partTextDelta(_, let partID, let text)? = delta.first else {
            Issue.record("expected partTextDelta, got \(delta)")
            return
        }
        #expect(partID == part.id)
        #expect(text == "Hel")

        let ended = decode(
            #"{"type":"session.text.ended","created":7,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","ordinal":1,"text":"Hello"}}"#,
            decoder: &decoder)
        guard case .partUpserted(_, let whole)? = ended.first else {
            Issue.record("expected partUpserted, got \(ended)")
            return
        }
        #expect(whole.id == part.id)
        #expect(whole.text == "Hello")
    }

    @Test func anEmptyThoughtIsTakenBackRatherThanLeftAsAHeading() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        _ = decode(
            #"{"type":"session.reasoning.started","created":1,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","ordinal":0}}"#,
            decoder: &decoder)
        let ended = decode(
            #"{"type":"session.reasoning.ended","created":2,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","ordinal":0,"text":""}}"#,
            decoder: &decoder)
        guard case .partRemoved(_, let partID)? = ended.first else {
            Issue.record("expected partRemoved, got \(ended)")
            return
        }
        #expect(partID == OpenCodeV2Mapping.reasoningPartID("msg_A", ordinal: 0))
    }

    @Test func aThoughtWithWordsStays() {
        let ended = decode(
            #"{"type":"session.reasoning.ended","created":2,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","ordinal":0,"text":"Let me look."}}"#
        )
        guard case .partUpserted(_, let part)? = ended.first, case .reasoning(let text) = part.kind
        else {
            Issue.record("expected reasoning part, got \(ended)")
            return
        }
        #expect(text == "Let me look.")
    }

    @Test func aToolCallKeepsItsNameAndInputThroughToItsResult() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        let started = decode(
            #"{"type":"session.tool.input.started","created":1,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_1","name":"shell"}}"#,
            decoder: &decoder)
        guard case .partUpserted(_, let pending)? = started.first,
            case .tool(let pendingCall) = pending.kind
        else {
            Issue.record("expected tool part, got \(started)")
            return
        }
        #expect(pending.id == OpenCodeV2Mapping.toolPartID("msg_A", callID: "call_1"))
        #expect(pendingCall.name == "shell")
        #expect(pendingCall.status == .pending)

        _ = decode(
            #"{"type":"session.tool.input.ended","created":2,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_1","text":"{\"command\":\"ls\"}"}}"#,
            decoder: &decoder)
        let called = decode(
            #"{"type":"session.tool.called","created":3,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_1","input":{"command":"ls -la /tmp/oc2a"},"executed":false}}"#,
            decoder: &decoder)
        guard case .partUpserted(_, let running)? = called.first,
            case .tool(let runningCall) = running.kind
        else {
            Issue.record("expected tool part, got \(called)")
            return
        }
        #expect(runningCall.status == .running)
        #expect(runningCall.input?["command"]?.stringValue == "ls -la /tmp/oc2a")

        let done = decode(
            #"{"type":"session.tool.success","created":4,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_1","content":[{"type":"text","text":"total 0\n."}],"metadata":{"title":"ls"},"executed":true}}"#,
            decoder: &decoder)
        #expect(done.count == 1)
        guard case .partUpserted(_, let completed)? = done.first,
            case .tool(let completedCall) = completed.kind
        else {
            Issue.record("expected tool part, got \(done)")
            return
        }
        #expect(completed.id == pending.id)
        #expect(completedCall.name == "shell")
        #expect(completedCall.status == .completed)
        #expect(completedCall.input?["command"]?.stringValue == "ls -la /tmp/oc2a")
        #expect(completedCall.output == "total 0\n.")
        #expect(completedCall.title == "ls")
    }

    @Test func aFailedToolCarriesTheServersOwnReason() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        _ = decode(
            #"{"type":"session.tool.called","created":3,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_2","name":"read","input":{"path":"x"},"executed":false}}"#,
            decoder: &decoder)
        let failed = decode(
            #"{"type":"session.tool.failed","created":4,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_2","error":{"type":"NotFound","message":"no such file"},"executed":true}}"#,
            decoder: &decoder)
        guard case .partUpserted(_, let part)? = failed.first, case .tool(let call) = part.kind
        else {
            Issue.record("expected tool part, got \(failed)")
            return
        }
        #expect(call.status == .error)
        #expect(call.output == "no such file")
        #expect(call.name == "read")
    }

    @Test func aPictureAToolHandsBackIsDockedAtTheCall() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        _ = decode(
            #"{"type":"session.tool.input.started","created":1,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_3","name":"screenshot"}}"#,
            decoder: &decoder)
        let done = decode(
            #"{"type":"session.tool.success","created":4,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","id":"call_3","content":[{"type":"text","text":"took it"},{"type":"file","uri":"data:image/png;base64,AAAA","mime":"image/png","name":"/tmp/shot.png"}],"executed":true}}"#,
            decoder: &decoder)
        #expect(done.count == 2)
        guard case .partUpserted(_, let picture)? = done.last, case .file(let file) = picture.kind
        else {
            Issue.record("expected file part, got \(done)")
            return
        }
        #expect(picture.id == OpenCodeV2Mapping.toolFilePartID("msg_A", callID: "call_3", index: 0))
        #expect(file.mime == "image/png")
        #expect(file.filename == "shot.png")
        #expect(file.url == "data:image/png;base64,AAAA")
    }

    @Test func aStepEndingClosesTheMessageWithItsBillAndFinishWord() {
        let events = decode(
            #"{"type":"session.step.ended","created":1789999437453,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","finish":"tool-calls","cost":0.01,"tokens":{"input":7698,"output":72,"reasoning":33,"cache":{"read":10,"write":2}}}}"#
        )
        guard case .messageUpserted(let message, _)? = events.first else {
            Issue.record("expected messageUpserted, got \(events)")
            return
        }
        #expect(message.completedAt == Date(timeIntervalSince1970: 1_789_999_437.453))
        #expect(!message.isStreaming)
        #expect(message.finishReason == "tool-calls")
        #expect(message.costUSD == 0.01)
        #expect(message.usage == MessageUsage(input: 7698, output: 72, reasoning: 33, cacheRead: 10, cacheWrite: 2))
        #expect(message.totalTokens == 7815)
    }

    @Test func aFailedStepIsAnErrorOnTheMessageAndAFailureOnTheStream() {
        let events = decode(
            #"{"type":"session.step.failed","created":9,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","error":{"type":"ProviderError","message":"rate limited"}}}"#
        )
        #expect(events.count == 2)
        guard case .messageUpserted(let message, _)? = events.first else {
            Issue.record("expected messageUpserted, got \(events)")
            return
        }
        #expect(message.error == "rate limited")
        #expect(message.finishReason == "error")
        guard case .failure(let failure)? = events.last else {
            Issue.record("expected failure, got \(events)")
            return
        }
        #expect(failure.message == "rate limited")
    }

    @Test func executionLifecycleIsTheTurnsStatus() {
        guard case .status(.running)? = decode(#"{"type":"session.execution.started","data":{"sessionID":"ses_S"}}"#).first else {
            Issue.record("expected running")
            return
        }
        guard case .status(.idle)? = decode(#"{"type":"session.execution.succeeded","data":{"sessionID":"ses_S"}}"#).first else {
            Issue.record("expected idle")
            return
        }
        guard case .status(.idle)? = decode(#"{"type":"session.idle","data":{"sessionID":"ses_S"}}"#).first else {
            Issue.record("expected idle")
            return
        }
        let failed = decode(#"{"type":"session.execution.failed","data":{"sessionID":"ses_S","error":{"type":"x","message":"boom"}}}"#)
        #expect(failed.count == 2)
        guard case .failure(let failure)? = failed.first, case .status(.idle)? = failed.last else {
            Issue.record("expected failure then idle, got \(failed)")
            return
        }
        #expect(failure.message == "boom")
    }

    @Test func aRetryIsATurnStillInFlight() {
        let events = decode(#"{"type":"session.status","data":{"sessionID":"ses_S","status":{"type":"retry","attempt":1,"message":"429","next":5}}}"#)
        guard case .status(.running)? = events.first else {
            Issue.record("expected running, got \(events)")
            return
        }
    }

    @Test func aPermissionAsksInTheServersWordsAndResolvesByRequestID() {
        let asked = decode(
            #"{"type":"permission.asked","data":{"id":"per_1","sessionID":"ses_S","action":"shell","resources":["rm -rf build"],"message":"Run rm -rf build?"}}"#
        )
        guard case .permission(let request)? = asked.first else {
            Issue.record("expected permission, got \(asked)")
            return
        }
        #expect(request.id == "per_1")
        #expect(request.sessionID == "ses_S")
        #expect(request.title == "Run rm -rf build?")
        #expect(request.toolName == "shell")

        let replied = decode(#"{"type":"permission.replied","data":{"sessionID":"ses_S","requestID":"per_1","reply":"once"}}"#)
        guard case .permissionResolved(let requestID)? = replied.first else {
            Issue.record("expected permissionResolved, got \(replied)")
            return
        }
        #expect(requestID == "per_1")
    }

    @Test func aPermissionWithoutWordsNamesItsActionAndResources() {
        let asked = decode(
            #"{"type":"permission.asked","data":{"id":"per_2","sessionID":"ses_S","action":"edit","resources":["src/a.swift","src/b.swift"]}}"#
        )
        guard case .permission(let request)? = asked.first else {
            Issue.record("expected permission, got \(asked)")
            return
        }
        #expect(request.title == "edit src/a.swift, src/b.swift")
    }

    @Test func aFormIsAQuestionAndResolvesByFormID() {
        let created = decode(
            #"{"type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_S","title":"Pick","fields":[{"key":"lang","type":"string","title":"Which language?","description":"For the new module","options":[{"value":"swift","label":"Swift","description":"Native"},{"value":"rust","label":"Rust"}]},{"key":"tests","type":"boolean","title":"Add tests?"}]}}}"#
        )
        guard case .question(let question)? = created.first else {
            Issue.record("expected question, got \(created)")
            return
        }
        #expect(question.id == "frm_1")
        #expect(question.sessionID == "ses_S")
        #expect(question.questions.count == 2)
        #expect(question.questions[0].question == "Which language?")
        #expect(question.questions[0].header == "For the new module")
        #expect(question.questions[0].options.map(\.label) == ["Swift", "Rust"])
        #expect(question.questions[0].custom == false)
        #expect(question.questions[1].options.map(\.label) == ["Yes", "No"])

        let replied = decode(#"{"type":"form.replied","data":{"id":"frm_1","sessionID":"ses_S","answer":{"lang":"swift"}}}"#)
        guard case .questionResolved(let id)? = replied.first else {
            Issue.record("expected questionResolved, got \(replied)")
            return
        }
        #expect(id == "frm_1")
    }

    @Test func compactionIsAnActivityWithAStartAnEndAndAReason() {
        let started = decode(#"{"type":"session.compaction.started","created":1000,"data":{"sessionID":"ses_S","reason":"manual","recent":""}}"#)
        guard case .compaction(let activity?)? = started.first else {
            Issue.record("expected compaction, got \(started)")
            return
        }
        #expect(activity.isRunning)
        #expect(activity.startedAt == Date(timeIntervalSince1970: 1))

        let ended = decode(#"{"type":"session.compaction.ended","created":2000,"data":{"sessionID":"ses_S","reason":"manual","text":"summary","recent":"","cost":0,"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}}"#)
        guard case .compaction(nil)? = ended.first else {
            Issue.record("expected compaction ended, got \(ended)")
            return
        }

        let failed = decode(#"{"type":"session.compaction.failed","created":3000,"data":{"sessionID":"ses_S","reason":"auto","error":{"type":"x","message":"context too small"}}}"#)
        guard case .compaction(let failure?)? = failed.first else {
            Issue.record("expected compaction failure, got \(failed)")
            return
        }
        #expect(failure.failure == "context too small")
    }

    @Test func theServersOwnBookkeepingDrawsNothing() {
        for type in ["session.inbox.enqueued", "session.instructions.updated", "session.usage.updated", "session.step.streamed", "session.viewed"] {
            let events = decode(#"{"type":"\#(type)","data":{"sessionID":"ses_S"}}"#)
            #expect(events.isEmpty, "\(type) should be silent")
        }
    }

    @Test func aNameNobodyKnowsIsReportedNotDropped() {
        let events = decode(#"{"type":"session.something.new","data":{"sessionID":"ses_S"}}"#)
        guard case .unknown(let type)? = events.first else {
            Issue.record("expected unknown, got \(events)")
            return
        }
        #expect(type == "session.something.new")
    }
}
