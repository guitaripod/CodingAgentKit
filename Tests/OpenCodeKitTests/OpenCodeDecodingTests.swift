import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

private let sessionID = "ses_S"

private func openCodeEvent(_ json: String) -> SSEvent {
    SSEvent(id: nil, type: nil, data: json)
}

private func decode(_ json: String) -> BackendEvent? {
    OpenCodeEventDecoder.decode(openCodeEvent(json), sessionID: sessionID)
}

@Suite struct OpenCodeEventDecoderTests {
    @Test func decodesTextPartUpdated() {
        let event = decode(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_S","part":{"type":"text","text":"Say hi","messageID":"msg_U","sessionID":"ses_S","id":"prt_1"}}}"#
        )
        guard case .partUpserted(let messageID, let part)? = event else {
            Issue.record("expected partUpserted, got \(String(describing: event))")
            return
        }
        #expect(messageID == "msg_U")
        #expect(part.id == "prt_1")
        #expect(part.text == "Say hi")
    }

    @Test func decodesToolPartUpdated() {
        let event = decode(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_S","part":{"type":"tool","callID":"call_1","tool":"bash","messageID":"msg_A","id":"prt_9","state":{"status":"completed","input":{"command":"ls"},"output":"file.txt","title":"ls"}}}}"#
        )
        guard case .partUpserted(_, let part)? = event, case .tool(let tool) = part.kind else {
            Issue.record("expected tool part, got \(String(describing: event))")
            return
        }
        #expect(tool.name == "bash")
        #expect(tool.status == .completed)
        #expect(tool.output == "file.txt")
    }

    @Test func decodesDeltaOnlyForTextField() {
        guard
            case .partTextDelta(_, _, let delta)? = decode(
                #"{"type":"message.part.delta","properties":{"sessionID":"ses_S","messageID":"msg_A","partID":"prt_2","field":"text","delta":"Hel"}}"#
            )
        else {
            Issue.record("expected text delta")
            return
        }
        #expect(delta == "Hel")
        #expect(
            decode(
                #"{"type":"message.part.delta","properties":{"sessionID":"ses_S","messageID":"m","partID":"p","field":"summary","delta":"x"}}"#
            ) == nil)
    }

    @Test func filtersEventsFromOtherSessions() {
        #expect(decode(#"{"type":"session.idle","properties":{"sessionID":"ses_OTHER"}}"#) == nil)
    }

    @Test func decodesIdleAndError() {
        guard
            case .status(.idle)? = decode(
                #"{"type":"session.idle","properties":{"sessionID":"ses_S"}}"#)
        else {
            Issue.record("expected idle")
            return
        }
        guard
            case .failure(let failure)? = decode(
                #"{"type":"session.error","properties":{"sessionID":"ses_S","error":{"name":"ProviderAuthError","data":{"message":"bad key"}}}}"#
            )
        else {
            Issue.record("expected failure")
            return
        }
        #expect(failure.message == "bad key")
    }

    @Test func decodesSessionStatusBusyAndIdle() {
        guard
            case .status(.running)? = decode(
                #"{"type":"session.status","properties":{"sessionID":"ses_S","status":{"type":"busy"}}}"#
            )
        else {
            Issue.record("expected running")
            return
        }
        guard
            case .status(.idle)? = decode(
                #"{"type":"session.status","properties":{"sessionID":"ses_S","status":{"type":"idle"}}}"#
            )
        else {
            Issue.record("expected idle")
            return
        }
    }

    @Test func decodesSessionStatusRetryAsQuotaWallFailure() {
        guard
            case .failure(let failure)? = decode(
                #"{"type":"session.status","properties":{"sessionID":"ses_S","status":{"type":"retry","attempt":1,"message":"monthly usage limit reached. It will reset in 3 days 5 hours.","action":{"reason":"account_rate_limit","provider":"opencode-go","title":"Go limit reached"}}}}"#
            )
        else {
            Issue.record("expected failure")
            return
        }
        #expect(failure.message.contains("usage limit"))
        #expect(failure.code == "account_rate_limit")
        #expect(failure.retryable)
    }

    @Test func unknownEventFallsBack() {
        guard
            case .unknown(let type)? = decode(
                #"{"type":"some.unknown.event","properties":{"sessionID":"ses_S"}}"#
            )
        else {
            Issue.record("expected unknown")
            return
        }
        #expect(type == "some.unknown.event")
    }
}

@Suite struct OpenCodeMappingTests {
    @Test func mapsAssistantEnvelopePartsIncludingUnknownAndTool() throws {
        let json = #"""
            {"info":{"id":"msg_A","role":"assistant","sessionID":"ses_S","time":{"created":1783352249094,"completed":1783352250000}},"parts":[{"id":"prt_0","messageID":"msg_A","sessionID":"ses_S","type":"step-start"},{"id":"prt_1","messageID":"msg_A","sessionID":"ses_S","type":"reasoning","text":"thinking"},{"id":"prt_2","messageID":"msg_A","sessionID":"ses_S","type":"text","text":"Hello"},{"id":"prt_3","messageID":"msg_A","sessionID":"ses_S","type":"tool","callID":"call_1","tool":"bash","state":{"status":"completed","input":{"command":"ls"},"output":"file.txt","title":"ls"}}]}
            """#
        let envelope = try JSONCoding.decoder.decode(OCMessageEnvelope.self, from: Data(json.utf8))
        let message = OpenCodeMapping.message(envelope)

        #expect(message.role == .assistant)
        #expect(message.agentType == .openCode)
        #expect(message.isStreaming == false)
        #expect(message.parts.count == 4)
        #expect(message.parts[0].kind == .unknown(type: "step-start"))

        guard case .reasoning(let reasoning) = message.parts[1].kind else {
            Issue.record("expected reasoning")
            return
        }
        #expect(reasoning == "thinking")

        guard case .tool(let tool) = message.parts[3].kind else {
            Issue.record("expected tool")
            return
        }
        #expect(tool.id == "call_1")
        #expect(tool.status == .completed)

        #expect(message.text == "Hello")
    }

    @Test func assistantWithoutCompletionIsStreaming() throws {
        let json =
            #"{"info":{"id":"msg_A","role":"assistant","sessionID":"ses_S","time":{"created":1}},"parts":[]}"#
        let envelope = try JSONCoding.decoder.decode(OCMessageEnvelope.self, from: Data(json.utf8))
        #expect(OpenCodeMapping.message(envelope).isStreaming == true)
    }

    @Test func aCompactionFoldsMarkerAndSummaryIntoOneSeam() throws {
        let json = #"""
            [{"info":{"id":"msg_U","role":"user","sessionID":"ses_S","time":{"created":1}},"parts":[{"id":"prt_c","messageID":"msg_U","sessionID":"ses_S","type":"compaction","auto":false}]},
             {"info":{"id":"msg_S","role":"assistant","sessionID":"ses_S","mode":"compaction","time":{"created":2,"completed":3}},"parts":[{"id":"prt_t","messageID":"msg_S","sessionID":"ses_S","type":"text","text":"Summary of everything."}]}]
            """#
        let envelopes = try JSONCoding.decoder.decode(
            [OCMessageEnvelope].self, from: Data(json.utf8))
        let transcript = OpenCodeMapping.transcript(envelopes)
        #expect(transcript.count == 1, "the marker message is dropped, the summary is the seam")
        guard let seam = transcript.first else { return }
        #expect(seam.role == .system)
        #expect(seam.parts.count == 1)
        guard case .compaction(let compaction) = seam.parts[0].kind else {
            Issue.record("expected a compaction part")
            return
        }
        #expect(compaction.trigger == .manual)
        #expect(compaction.summary == "Summary of everything.")
    }

    @Test func anAutoCompactionRemembersWhoAsked() throws {
        let json = #"""
            [{"info":{"id":"msg_U","role":"user","sessionID":"ses_S","time":{"created":1}},"parts":[{"id":"prt_c","messageID":"msg_U","sessionID":"ses_S","type":"compaction","auto":true}]},
             {"info":{"id":"msg_S","role":"assistant","sessionID":"ses_S","mode":"compaction","time":{"created":2,"completed":3}},"parts":[{"id":"prt_t","messageID":"msg_S","sessionID":"ses_S","type":"text","text":"S"}]}]
            """#
        let envelopes = try JSONCoding.decoder.decode(
            [OCMessageEnvelope].self, from: Data(json.utf8))
        guard case .compaction(let compaction)? = OpenCodeMapping.transcript(envelopes).first?.parts.first?.kind
        else {
            Issue.record("expected a compaction part")
            return
        }
        #expect(compaction.trigger == .auto)
    }

    @Test func aRunningMarkerLeavesTheTranscriptUntouched() throws {
        let json = #"""
            [{"info":{"id":"msg_U","role":"user","sessionID":"ses_S","time":{"created":1}},"parts":[{"id":"prt_c","messageID":"msg_U","sessionID":"ses_S","type":"compaction","auto":false}]}]
            """#
        let envelopes = try JSONCoding.decoder.decode(
            [OCMessageEnvelope].self, from: Data(json.utf8))
        #expect(OpenCodeMapping.transcript(envelopes).isEmpty)
    }

    @Test func aDanglingMarkerIsTheRunningCompactionTheTranscriptRemembers() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let json = """
            [{"info":{"id":"msg_U","role":"user","sessionID":"ses_S","time":{"created":\(Int(started.timeIntervalSince1970 * 1000))}},"parts":[{"id":"prt_c","messageID":"msg_U","sessionID":"ses_S","type":"compaction","auto":false}]}]
            """
        let envelopes = try JSONCoding.decoder.decode(
            [OCMessageEnvelope].self, from: Data(json.utf8))
        #expect(
            OpenCodeMapping.compactionInFlight(envelopes, now: started.addingTimeInterval(90))
                == started)
        #expect(
            OpenCodeMapping.compactionInFlight(
                envelopes, now: started.addingTimeInterval(OpenCodeMapping.staleMarker + 1)) == nil,
            "a marker nothing ever answered stops speaking rather than pinning the card forever")
    }

    @Test func aMarkerItsSummaryAnsweredIsNoLongerRunning() throws {
        let json = #"""
            [{"info":{"id":"msg_U","role":"user","sessionID":"ses_S","time":{"created":1}},"parts":[{"id":"prt_c","messageID":"msg_U","sessionID":"ses_S","type":"compaction","auto":false}]},
             {"info":{"id":"msg_S","role":"assistant","sessionID":"ses_S","mode":"compaction","time":{"created":2,"completed":3}},"parts":[{"id":"prt_t","messageID":"msg_S","sessionID":"ses_S","type":"text","text":"S"}]}]
            """#
        let envelopes = try JSONCoding.decoder.decode(
            [OCMessageEnvelope].self, from: Data(json.utf8))
        #expect(OpenCodeMapping.compactionInFlight(envelopes, now: Date()) == nil)
    }

    @Test func aMarkerPartEventIsTheRunningActivityNotATranscriptRow() {
        let event = decode(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_S","part":{"type":"compaction","auto":false,"messageID":"msg_U","sessionID":"ses_S","id":"prt_c"}}}"#
        )
        guard case .compaction(.some(let activity))? = event else {
            Issue.record("expected a compaction activity, got \(String(describing: event))")
            return
        }
        #expect(activity.isRunning)
    }

    @Test func aCompletedCompactionModeMessageEndsTheActivity() {
        let event = decode(
            #"{"type":"message.updated","properties":{"sessionID":"ses_S","info":{"id":"msg_S","role":"assistant","sessionID":"ses_S","mode":"compaction","time":{"created":2,"completed":3}}}}"#
        )
        guard case .compaction(let activity)? = event else {
            Issue.record("expected a compaction activity, got \(String(describing: event))")
            return
        }
        #expect(activity == nil)
    }
}

@Suite struct OpenCodeReducerIntegrationTests {
    @Test func foldsFullStreamingTurn() {
        var reducer = MessageReducer(agentType: .openCode)
        let events = [
            #"{"type":"message.updated","properties":{"sessionID":"ses_S","info":{"id":"msg_U","role":"user","sessionID":"ses_S","time":{"created":1}}}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_S","part":{"type":"text","text":"Say hi","messageID":"msg_U","sessionID":"ses_S","id":"prt_u"}}}"#,
            #"{"type":"message.updated","properties":{"sessionID":"ses_S","info":{"id":"msg_A","role":"assistant","sessionID":"ses_S","time":{"created":2}}}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_S","part":{"type":"reasoning","text":"hmm","messageID":"msg_A","sessionID":"ses_S","id":"prt_r"}}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_S","part":{"type":"text","text":"","messageID":"msg_A","sessionID":"ses_S","id":"prt_t"}}}"#,
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_S","messageID":"msg_A","partID":"prt_t","field":"text","delta":"Hel"}}"#,
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_S","messageID":"msg_A","partID":"prt_t","field":"text","delta":"lo"}}"#,
            #"{"type":"session.idle","properties":{"sessionID":"ses_S"}}"#,
        ]
        for json in events {
            if let event = decode(json) { reducer.apply(event) }
        }

        #expect(reducer.snapshot.map(\.id) == ["msg_U", "msg_A"])
        #expect(reducer.snapshot[0].text == "Say hi")
        #expect(reducer.snapshot[1].text == "Hello")
        #expect(
            reducer.snapshot[1].parts.contains {
                if case .reasoning = $0.kind { return true } else { return false }
            })
    }
}

@Suite struct OpenCodeQuestionTests {
    @Test func decodesQuestionAsked() {
        let json = #"""
        {"type":"question.asked","properties":{"id":"que_1","sessionID":"ses_S","questions":[{"question":"Which database?","header":"Database","options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite","description":"Embedded"}],"multiple":false,"custom":true}]}}
        """#
        guard case .question(let request)? = decode(json) else {
            Issue.record("expected question event")
            return
        }
        #expect(request.id == "que_1")
        #expect(request.questions.count == 1)
        #expect(request.questions[0].header == "Database")
        #expect(request.questions[0].options.map(\.label) == ["Postgres", "SQLite"])
        #expect(request.questions[0].custom)
        #expect(!request.questions[0].multiple)
    }

    @Test func decodesV2AskedAndResolution() {
        let asked = #"{"type":"question.v2.asked","properties":{"id":"que_2","sessionID":"ses_S","questions":[{"question":"Q?","header":"H","options":[]}]}}"#
        guard case .question(let request)? = decode(asked) else {
            Issue.record("expected v2 question")
            return
        }
        #expect(request.id == "que_2")
        guard
            case .questionResolved(let id)? = decode(
                #"{"type":"question.replied","properties":{"sessionID":"ses_S","requestID":"que_2","answers":[["A"]]}}"#)
        else {
            Issue.record("expected resolution")
            return
        }
        #expect(id == "que_2")
    }

    @Test func filtersQuestionFromOtherSession() {
        let json = #"{"type":"question.asked","properties":{"id":"que_3","sessionID":"ses_OTHER","questions":[{"question":"Q?","header":"H","options":[]}]}}"#
        #expect(decode(json) == nil)
    }
}

@Suite struct OpenCodeSessionModelTests {
    private func session(_ json: String) throws -> AgentSession {
        OpenCodeMapping.session(try JSONDecoder().decode(OCSession.self, from: Data(json.utf8)))
    }

    @Test func sessionRecordModelReachesTheSession() throws {
        let mapped = try session(
            #"{"id":"ses_S","title":"T","model":{"id":"deepseek-v4-flash","providerID":"opencode-go","variant":"max"}}"#
        )
        #expect(mapped.model == "deepseek-v4-flash")
        #expect(mapped.modelProviderID == "opencode-go")
        #expect(mapped.reasoningEffort == "max")
    }

    @Test func sessionRecordModelReadsTheModelIDSpelling() throws {
        let mapped = try session(
            #"{"id":"ses_S","model":{"modelID":"deepseek-v4-flash","providerID":"opencode-go"}}"#
        )
        #expect(mapped.model == "deepseek-v4-flash")
        #expect(mapped.modelProviderID == "opencode-go")
        #expect(mapped.reasoningEffort == nil)
    }

    @Test func sessionRecordWithoutAModelStaysSilent() throws {
        let mapped = try session(#"{"id":"ses_S","title":"T"}"#)
        #expect(mapped.model == nil)
        #expect(mapped.modelProviderID == nil)
        #expect(mapped.reasoningEffort == nil)
    }
}
