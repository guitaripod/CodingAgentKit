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

    @Test func aDeliveredPromptIsTheUserMessageATranscriptReadWouldShow() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        let enqueued = decode(
            #"{"type":"session.inbox.enqueued","created":1790181060112,"data":{"inboxID":"msg_U","sessionID":"ses_S","item":{"type":"user","payload":{"text":"Reply with just: ok","files":[{"data":"AAAA","mime":"image/png","name":"a.png","source":{"type":"uri","uri":"file:///tmp/a.png"}}]},"delivery":"steer"}}}"#,
            decoder: &decoder)
        #expect(enqueued.isEmpty)

        let delivered = decode(
            #"{"type":"session.inbox.delivered","created":1790181060127,"data":{"sessionID":"ses_S","inboxID":"msg_U"}}"#,
            decoder: &decoder)
        guard case .messageUpserted(let message, let replaceParts)? = delivered.first, delivered.count == 1 else {
            Issue.record("expected one messageUpserted, got \(delivered)")
            return
        }
        #expect(replaceParts)
        #expect(message.id == "msg_U")
        #expect(message.role == .user)
        #expect(message.parts.map(\.id) == ["msg_U/text", "msg_U/file/0"])
        #expect(message.parts.first?.text == "Reply with just: ok")
        #expect(message.createdAt == Date(timeIntervalSince1970: 1_790_181_060.127))

        let again = decode(
            #"{"type":"session.inbox.delivered","created":1790181060130,"data":{"sessionID":"ses_S","inboxID":"msg_U"}}"#,
            decoder: &decoder)
        #expect(again.isEmpty)
    }

    @Test func aShellRunBesideTheChatAppearsWhenItStartsAndSettlesWhenItEnds() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        let started = decode(
            #"{"id":"evt_0cf1SHELL","type":"session.shell.started","created":1000,"data":{"sessionID":"ses_S","shell":{"id":"sh_1","status":"running","command":"git status","cwd":"/tmp","shell":"bash","file":"/tmp/o","metadata":{},"time":{"started":1000}}}}"#,
            decoder: &decoder)
        guard case .messageUpserted(let running, true)? = started.first else {
            Issue.record("expected messageUpserted, got \(started)")
            return
        }
        #expect(running.id == "msg_0cf1SHELL")
        #expect(running.isStreaming)
        guard case .tool(let call) = running.parts.first?.kind else {
            Issue.record("expected tool part")
            return
        }
        #expect(call.status == .running)
        #expect(call.input?["command"]?.stringValue == "git status")

        let ended = decode(
            #"{"id":"evt_0cf1SHELL2","type":"session.shell.ended","created":2500,"data":{"sessionID":"ses_S","shell":{"id":"sh_1","status":"exited","exit":1,"command":"git status","cwd":"/tmp","shell":"bash","file":"/tmp/o","metadata":{},"time":{"started":1000,"completed":2500}},"output":{"output":"fatal: not a git repository","cursor":28,"size":28,"truncated":false}}}"#,
            decoder: &decoder)
        guard case .messageUpserted(let settled, true)? = ended.first else {
            Issue.record("expected messageUpserted, got \(ended)")
            return
        }
        #expect(settled.id == running.id)
        #expect(!settled.isStreaming)
        #expect(settled.parts.map(\.id) == running.parts.map(\.id))
        guard case .tool(let finished) = settled.parts.first?.kind else {
            Issue.record("expected tool part")
            return
        }
        #expect(finished.status == .error)
        #expect(finished.output == "fatal: not a git repository")
    }

    @Test func aStepSomebodyStoppedClosesTheMessageWithoutAFailure() {
        let events = decode(
            #"{"type":"session.step.failed","created":5,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","error":{"type":"aborted","message":"Step interrupted"}}}"#
        )
        #expect(events.count == 1)
        guard case .messageUpserted(let message, _)? = events.first else {
            Issue.record("expected messageUpserted, got \(events)")
            return
        }
        #expect(message.error == nil)
        #expect(message.finishReason == "aborted")
    }

    @Test func aTurnTheServerGaveUpResumingIsAFailureInItsOwnWords() {
        let events = decode(
            #"{"type":"session.execution.failed","created":6,"data":{"sessionID":"ses_S","error":{"type":"aborted","message":"Execution was interrupted repeatedly and will not be resumed automatically."}}}"#
        )
        guard case .failure(let failure)? = events.first else {
            Issue.record("expected failure, got \(events)")
            return
        }
        #expect(failure.message.hasPrefix("Execution was interrupted repeatedly"))
    }

    @Test func aProviderWaitCarriesItsReasonClockAndRemedyUntilAnAttemptAnswers() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        let waiting = decode(
            #"{"type":"session.status","created":10,"data":{"sessionID":"ses_S","status":{"type":"retry","attempt":2,"message":"Rate limit reached for requests","next":1790000060000,"action":{"reason":"usage","provider":"openai","title":"Usage limit","message":"You have used this plan's limit","label":"Upgrade","link":"https://example.com/upgrade"}}}}"#,
            decoder: &decoder)
        guard waiting.count == 2, case .status(.running) = waiting[0],
            case .retry(let retry?) = waiting[1]
        else {
            Issue.record("expected running then retry, got \(waiting)")
            return
        }
        #expect(retry.attempt == 2)
        #expect(retry.reason == "Rate limit reached for requests")
        #expect(retry.nextAttemptAt == Date(timeIntervalSince1970: 1_790_000_060))
        #expect(retry.remedy?.label == "Upgrade")
        #expect(retry.remedy?.link == "https://example.com/upgrade")

        let scheduled = decode(
            #"{"type":"session.retry.scheduled","created":11,"data":{"sessionID":"ses_S","assistantMessageID":"msg_A","attempt":2,"at":1790000061000,"error":{"type":"provider","message":"Rate limit reached for requests"}}}"#,
            decoder: &decoder)
        guard case .retry(let merged?)? = scheduled.first else {
            Issue.record("expected retry, got \(scheduled)")
            return
        }
        #expect(merged.remedy?.label == "Upgrade")
        #expect(merged.nextAttemptAt == Date(timeIntervalSince1970: 1_790_000_061))

        let answering = decode(
            #"{"type":"session.step.started","created":12,"data":{"sessionID":"ses_S","agent":"build","model":{"id":"m","providerID":"p"},"assistantMessageID":"msg_A","started":12}}"#,
            decoder: &decoder)
        #expect(answering.contains { if case .retry(nil) = $0 { return true } else { return false } })
        let quiet = decode(
            #"{"type":"session.status","created":13,"data":{"sessionID":"ses_S","status":{"type":"busy"}}}"#,
            decoder: &decoder)
        #expect(!quiet.contains { if case .retry = $0 { return true } else { return false } })
    }

    @Test func aModelOrAgentChangingHandsIsANoteUnderTheRecordsOwnID() {
        let model = decode(
            #"{"id":"evt_0cf1MODEL","type":"session.model.selected","created":20,"data":{"sessionID":"ses_S","model":{"id":"glm-5.3-flash","providerID":"ollama-cloud","variant":"high"},"previous":{"id":"qwen38","providerID":"llama-server"}}}"#
        )
        guard case .messageUpserted(let note, true)? = model.first,
            case .note(let value)? = note.parts.first?.kind,
            case .model(let to, let effort, let previous) = value.subject
        else {
            Issue.record("expected a model note, got \(model)")
            return
        }
        #expect(note.id == "msg_0cf1MODEL")
        #expect(note.role == .system)
        #expect(to == ModelSelection(providerID: "ollama-cloud", modelID: "glm-5.3-flash"))
        #expect(effort == "high")
        #expect(previous == ModelSelection(providerID: "llama-server", modelID: "qwen38"))

        let agent = decode(
            #"{"id":"evt_0cf1AGENT","type":"session.agent.selected","created":21,"data":{"sessionID":"ses_S","agent":"plan","previous":"build"}}"#
        )
        guard case .messageUpserted(let agentNote, _)? = agent.first,
            case .note(let agentValue)? = agentNote.parts.first?.kind,
            case .agent("plan", previous: "build") = agentValue.subject
        else {
            Issue.record("expected an agent note, got \(agent)")
            return
        }
        let unchanged = decode(
            #"{"id":"evt_0cf1SAME","type":"session.agent.selected","created":22,"data":{"sessionID":"ses_S","agent":"build","previous":"build"}}"#
        )
        #expect(unchanged.isEmpty)
        let first = decode(
            #"{"id":"evt_0cf1FIRST","type":"session.model.selected","created":23,"data":{"sessionID":"ses_S","model":{"id":"glm","providerID":"ollama-cloud"}}}"#
        )
        #expect(first.isEmpty)

        var underway = OpenCodeV2EventDecoder(sessionID: sessionID)
        _ = decode(
            #"{"type":"session.inbox.enqueued","created":1,"data":{"inboxID":"msg_U","sessionID":"ses_S","item":{"type":"user","payload":{"text":"go"},"delivery":"steer"}}}"#,
            decoder: &underway)
        let chosen = decode(
            #"{"id":"evt_0cf1PLAN","type":"session.agent.selected","created":24,"data":{"sessionID":"ses_S","agent":"plan"}}"#,
            decoder: &underway)
        guard case .messageUpserted(let planned, _)? = chosen.first,
            case .note(let plan)? = planned.parts.first?.kind,
            case .agent("plan", previous: nil) = plan.subject
        else {
            Issue.record("expected the first agent choice mid-conversation to be a note, got \(chosen)")
            return
        }
    }

    @Test func aLineWrittenThroughTheInboxIsANoteWhenItIsDelivered() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        let enqueued = decode(
            #"{"type":"session.inbox.enqueued","created":1,"data":{"inboxID":"msg_R","sessionID":"ses_S","item":{"type":"synthetic","payload":{"text":"The server restarted while you were working.","description":"Continuing after restart"},"delivery":"steer"}}}"#,
            decoder: &decoder)
        #expect(enqueued.isEmpty)
        let delivered = decode(
            #"{"type":"session.inbox.delivered","created":2,"data":{"sessionID":"ses_S","inboxID":"msg_R"}}"#,
            decoder: &decoder)
        guard case .messageUpserted(let note, true)? = delivered.first,
            case .note(let value)? = note.parts.first?.kind
        else {
            Issue.record("expected a note, got \(delivered)")
            return
        }
        #expect(note.id == "msg_R")
        #expect(value.subject == .resumedAfterRestart)

        _ = decode(
            #"{"type":"session.inbox.enqueued","created":3,"data":{"inboxID":"msg_H","sessionID":"ses_S","item":{"type":"synthetic","payload":{"text":"The previous turn stopped.","metadata":{"interruption":"dismissed"}},"delivery":"steer"}}}"#,
            decoder: &decoder)
        #expect(
            decode(
                #"{"type":"session.inbox.delivered","created":4,"data":{"sessionID":"ses_S","inboxID":"msg_H"}}"#,
                decoder: &decoder
            ).isEmpty)
    }

    @Test func aLineWrittenForTheReaderIsANoteAndOneForTheModelAloneIsNot() {
        func subject(_ json: String) -> TranscriptNote.Subject? {
            guard case .messageUpserted(let message, _)? = decode(json).first,
                case .note(let note)? = message.parts.first?.kind
            else { return nil }
            return note.subject
        }
        #expect(
            subject(#"{"id":"evt_1","type":"session.synthetic","created":1,"data":{"sessionID":"ses_S","text":"The server restarted while you were working.","description":"Continuing after restart"}}"#)
                == .resumedAfterRestart)
        #expect(
            subject(#"{"id":"evt_2","type":"session.synthetic","created":1,"data":{"sessionID":"ses_S","text":"<shell ...>","description":"cargo test","metadata":{"source":"shell","shellID":"sh_1","state":"error"}}}"#)
                == .workFinished("cargo test", work: .command, outcome: .failed))
        #expect(
            subject(#"{"id":"evt_3","type":"session.synthetic","created":1,"data":{"sessionID":"ses_S","text":"<subagent ...>","description":"Audit the parser","metadata":{"source":"subagent","childID":"ses_C","state":"completed"}}}"#)
                == .workFinished("Audit the parser", work: .agent, outcome: .completed))
        #expect(
            subject(#"{"id":"evt_4","type":"session.synthetic","created":1,"data":{"sessionID":"ses_S","text":"Instructions from: /a/AGENTS.md","description":"Loaded src/AGENTS.md","metadata":{"instruction":{"paths":["/a/AGENTS.md"]}}}}"#)
                == .instructions("Loaded src/AGENTS.md"))
        #expect(
            decode(#"{"id":"evt_5","type":"session.instructions.updated","created":1,"data":{"sessionID":"ses_S","delta":{"core/codemode":{}},"text":"updated"}}"#)
                .isEmpty)
        #expect(
            subject(#"{"id":"evt_6","type":"session.skill.activated","created":1,"data":{"sessionID":"ses_S","id":"skl_1","name":"review","text":"..."}}"#)
                == .skill("review"))
        #expect(
            decode(#"{"id":"evt_7","type":"session.synthetic","created":1,"data":{"sessionID":"ses_S","text":"Plan mode is active."}}"#)
                .isEmpty)
        #expect(
            decode(#"{"id":"evt_8","type":"session.instructions.updated","created":1,"data":{"sessionID":"ses_S","delta":{"AGENTS.md":{}}}}"#)
                .isEmpty)
    }

    @Test func aRevertStandsUntilItIsUndoneOrMadeFinal() {
        let staged = decode(
            #"{"type":"session.revert.staged","created":30,"data":{"sessionID":"ses_S","revert":{"messageID":"msg_U2","snapshot":"abc","files":[{"file":"src/a.swift","status":"modified","additions":3,"deletions":1},{"file":"src/new.swift","status":"added","additions":10,"deletions":0}]}}}"#
        )
        guard case .revert(let revert?)? = staged.first else {
            Issue.record("expected a revert, got \(staged)")
            return
        }
        #expect(revert.messageID == "msg_U2")
        #expect(revert.files.map(\.path) == ["src/a.swift", "src/new.swift"])
        #expect(revert.files.map(\.change) == [.modified, .added])
        #expect(revert.files.first?.additions == 3)
        guard case .revert(nil)? = decode(#"{"type":"session.revert.cleared","created":31,"data":{"sessionID":"ses_S"}}"#).first
        else {
            Issue.record("expected the revert to clear")
            return
        }
        let committed = decode(
            #"{"type":"session.revert.committed","created":32,"data":{"sessionID":"ses_S","to":"msg_U2"}}"#)
        #expect(committed.count == 2)
        guard case .revertCommitted(let boundary) = committed[0], case .resync = committed[1] else {
            Issue.record("expected the revert made final at its boundary and a re-read, got \(committed)")
            return
        }
        #expect(boundary == "msg_U2")
    }

    @Test func aCancelledPromptNeverBecomesAMessage() {
        var decoder = OpenCodeV2EventDecoder(sessionID: sessionID)
        _ = decode(
            #"{"type":"session.inbox.enqueued","created":1,"data":{"inboxID":"msg_U","sessionID":"ses_S","item":{"type":"user","payload":{"text":"never mind"},"delivery":"queue"}}}"#,
            decoder: &decoder)
        _ = decode(
            #"{"type":"session.inbox.cancelled","created":2,"data":{"sessionID":"ses_S","inboxID":"msg_U"}}"#,
            decoder: &decoder)
        let delivered = decode(
            #"{"type":"session.inbox.delivered","created":3,"data":{"sessionID":"ses_S","inboxID":"msg_U"}}"#,
            decoder: &decoder)
        #expect(delivered.isEmpty)
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
