import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

/// A turn as opencode 2.0.11 stored it: the prompt, a step that called a shell, the step that
/// answered, and the idle marker — oldest first, the way the client reads them back.
private let capturedTranscript = #"""
    [
      {"id":"msg_U","time":{"created":1789999433515},"text":"Run the shell command `ls -la /tmp/oc2a` and then tell me in one sentence what you saw.","type":"user"},
      {"id":"msg_A1","time":{"created":1789999433524,"streamed":1789999437422,"completed":1789999437453},"type":"assistant","agent":"build","model":{"id":"muse","providerID":"opencode"},"content":[{"type":"reasoning","text":"","state":{"itemId":"rs_1"}},{"type":"text","text":"Running that listing now.","state":{"itemId":"rs_2"}},{"type":"tool","id":"call_1","name":"shell","executed":true,"state":{"status":"completed","input":{"command":"ls -la /tmp/oc2a"},"content":[{"type":"text","text":"total 0\ndrwxr-xr-x  2 marcus  wheel  64 Sep 21 17:03 ."}],"metadata":{"shellID":"sh_1"}},"time":{"created":1789999433800,"ran":1789999437100,"completed":1789999437400}}],"finish":"tool-calls","cost":0,"tokens":{"input":7698,"output":72,"reasoning":33,"cache":{"read":0,"write":0}}},
      {"id":"msg_A2","time":{"created":1789999437463,"streamed":1789999438975,"completed":1789999438977},"type":"assistant","agent":"build","model":{"id":"muse","providerID":"opencode"},"content":[{"type":"reasoning","text":"","state":{}},{"type":"text","text":"I saw that `/tmp/oc2a` is an empty directory.","state":{}}],"finish":"stop","cost":0,"tokens":{"input":218,"output":32,"reasoning":37,"cache":{"read":7665,"write":0}}},
      {"id":"msg_I","time":{"created":1789999438981},"type":"idle","outcome":"succeeded"}
    ]
    """#

private func records(_ json: String) throws -> [OC2Message] {
    try JSONCoding.decoder.decode([OC2Message].self, from: Data(json.utf8))
}

@Suite struct OpenCodeV2MappingTests {
    @Test func aStoredTurnReadsAsThreeMessagesWithTheStreamsOwnPartIDs() throws {
        let transcript = OpenCodeV2Mapping.transcript(try records(capturedTranscript))
        #expect(transcript.map(\.id) == ["msg_U", "msg_A1", "msg_A2"])

        let prompt = transcript[0]
        #expect(prompt.role == .user)
        #expect(prompt.text.hasPrefix("Run the shell command"))

        let step = transcript[1]
        #expect(step.role == .assistant)
        #expect(!step.isStreaming)
        #expect(step.completedAt == Date(timeIntervalSince1970: 1_789_999_437.453))
        #expect(step.finishReason == "tool-calls")
        #expect(step.modelID == "muse")
        #expect(step.providerID == "opencode")
        #expect(step.usage?.input == 7698)
        #expect(step.parts.map(\.id) == [
            OpenCodeV2Mapping.textPartID("msg_A1", ordinal: 0),
            OpenCodeV2Mapping.toolPartID("msg_A1", callID: "call_1"),
        ])
        #expect(step.parts[0].text == "Running that listing now.")
        #expect(step.parts[0].startedAt == nil)
        guard case .tool(let call) = step.parts[1].kind else {
            Issue.record("expected tool part")
            return
        }
        #expect(call.name == "shell")
        #expect(call.status == .completed)
        #expect(call.input?["command"]?.stringValue == "ls -la /tmp/oc2a")
        #expect(call.output?.hasPrefix("total 0") == true)

        let answer = transcript[2]
        #expect(answer.parts.count == 1)
        #expect(answer.parts[0].id == OpenCodeV2Mapping.textPartID("msg_A2", ordinal: 0))
        #expect(answer.finishReason == "stop")
    }

    @Test func aThoughtWithWordsIsAPartAndCountsByItsOwnOrdinal() throws {
        let message = try records(#"""
            [{"id":"msg_A","time":{"created":1},"type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"reasoning","text":"","state":{}},{"type":"text","text":"a"},{"type":"reasoning","text":"thinking","time":{"created":1789999433800}},{"type":"text","text":"b"}]}]
            """#)
        let transcript = OpenCodeV2Mapping.transcript(message)
        #expect(transcript[0].parts.map(\.id) == [
            OpenCodeV2Mapping.textPartID("msg_A", ordinal: 0),
            OpenCodeV2Mapping.reasoningPartID("msg_A", ordinal: 1),
            OpenCodeV2Mapping.textPartID("msg_A", ordinal: 1),
        ])
        #expect(transcript[0].parts[1].startedAt == Date(timeIntervalSince1970: 1_789_999_433.8))
        #expect(transcript[0].isStreaming)
    }

    @Test func aToolStillRunningWhenTheMessageClosedWasStoppedNotFinished() throws {
        let message = try records(#"""
            [{"id":"msg_A","time":{"created":1,"completed":2},"type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"tool","id":"c","name":"shell","state":{"status":"running","input":{"command":"sleep 99"},"metadata":{}},"time":{"created":1}}],"finish":"abort"}]
            """#)
        guard case .tool(let call) = OpenCodeV2Mapping.transcript(message)[0].parts[0].kind else {
            Issue.record("expected tool part")
            return
        }
        #expect(call.status == .stopped)
    }

    @Test func aFinishedCompactionIsASeamAndARunningOneIsTheActivity() throws {
        let done = try records(#"""
            [{"id":"msg_C","time":{"created":1789999000000},"type":"compaction","status":"completed","reason":"auto","summary":"We did things.","recent":""}]
            """#)
        let transcript = OpenCodeV2Mapping.transcript(done)
        #expect(transcript.count == 1)
        #expect(transcript[0].role == .system)
        guard case .compaction(let seam) = transcript[0].parts[0].kind else {
            Issue.record("expected compaction part")
            return
        }
        #expect(seam.trigger == .auto)
        #expect(seam.summary == "We did things.")
        #expect(OpenCodeV2Mapping.compactionInFlight(done) == nil)

        let now = Date(timeIntervalSince1970: 1_789_999_100)
        let running = try records(#"""
            [{"id":"msg_U","time":{"created":1789998000000},"text":"hi","type":"user"},{"id":"msg_C","time":{"created":1789999000000},"type":"compaction","status":"running","reason":"manual","summary":"","recent":""}]
            """#)
        #expect(OpenCodeV2Mapping.transcript(running).map(\.id) == ["msg_U"])
        #expect(OpenCodeV2Mapping.compactionInFlight(running, now: now) == Date(timeIntervalSince1970: 1_789_999_000))
        #expect(OpenCodeV2Mapping.compactionInFlight(running, now: now.addingTimeInterval(31 * 60)) == nil)

        let overtaken = try records(#"""
            [{"id":"msg_C","time":{"created":1789999000000},"type":"compaction","status":"running","reason":"manual","summary":"","recent":""},{"id":"msg_U","time":{"created":1789999050000},"text":"hi","type":"user"}]
            """#)
        #expect(OpenCodeV2Mapping.compactionInFlight(overtaken, now: now) == nil)
    }

    @Test func aShellThePersonRanIsATheToolItAmountsTo() throws {
        let shell = try records(#"""
            [{"id":"msg_S","time":{"created":1,"completed":2},"type":"shell","shellID":"sh_1","command":"git status","status":"exited","exit":0,"output":{"output":"clean","cursor":5,"size":5,"truncated":false}}]
            """#)
        let transcript = OpenCodeV2Mapping.transcript(shell)
        guard case .tool(let call) = transcript[0].parts[0].kind else {
            Issue.record("expected tool part")
            return
        }
        #expect(call.name == "shell")
        #expect(call.status == .completed)
        #expect(call.output == "clean")
        #expect(call.input?["command"]?.stringValue == "git status")
    }

    @Test func aUsersPictureIsAFilePart() throws {
        let message = try records(#"""
            [{"id":"msg_U","time":{"created":1},"text":"look","files":[{"data":"AAAA","mime":"image/png","name":"/Users/me/shot.png","source":{"type":"inline"}},{"data":"QUJD","mime":"text/plain","name":"notes.txt","source":{"type":"uri","uri":"file:///home/me/notes.txt"}}],"type":"user"}]
            """#)
        let parts = OpenCodeV2Mapping.transcript(message)[0].parts
        #expect(parts.map(\.id) == ["msg_U/text", "msg_U/file/0", "msg_U/file/1"])
        guard case .file(let file) = parts[1].kind, case .file(let notes) = parts[2].kind else {
            Issue.record("expected file parts")
            return
        }
        #expect(file.filename == "shot.png")
        #expect(file.mime == "image/png")
        #expect(file.url == "data:image/png;base64,AAAA")
        #expect(notes.url == "data:text/plain;base64,QUJD")
        #expect(try OpenCodeCommon.attachmentData(notes) == Data("ABC".utf8))
    }

    @Test func aShellThatRanOutOfTimeOrWasKilledFailedWithoutAnExitCode() throws {
        for status in ["timeout", "killed"] {
            let shell = try records(#"""
                [{"id":"msg_S","time":{"created":1,"completed":2},"type":"shell","shellID":"sh_1","command":"sleep 99","status":"\#(status)"}]
                """#)
            guard case .tool(let call) = OpenCodeV2Mapping.transcript(shell)[0].parts[0].kind else {
                Issue.record("expected tool part")
                return
            }
            #expect(call.status == .error)
        }
    }

    @Test func aStepSomebodyStoppedIsNotAnError() throws {
        let stopped = try records(#"""
            [{"id":"msg_A","time":{"created":1,"completed":2},"type":"assistant","agent":"build","model":{"id":"muse","providerID":"opencode"},"content":[],"error":{"type":"aborted","message":"Step interrupted"}}]
            """#)
        let message = OpenCodeV2Mapping.transcript(stopped)[0]
        #expect(message.error == nil)
        #expect(message.finishReason == "aborted")
        #expect(!message.isAnswerless)
    }

    @Test func theSessionClockIsTheLaterOfWrittenAndSettled() throws {
        let record = try JSONCoding.decoder.decode(
            OC2Session.self,
            from: Data(#"{"id":"ses_1","projectID":"p","cost":0.5,"tokens":{"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1000,"updated":2000,"idle":3000},"location":{"directory":"/tmp/a"},"model":{"id":"m","providerID":"p","variant":"high"}}"#.utf8))
        let session = OpenCodeV2Mapping.session(record, running: nil)
        #expect(session.updatedAt == Date(timeIntervalSince1970: 3))
        #expect(session.createdAt == Date(timeIntervalSince1970: 1))
        #expect(session.title == "ses_1")
        #expect(session.directory == "/tmp/a")
        #expect(session.model == "m")
        #expect(session.modelProviderID == "p")
        #expect(session.reasoningEffort == "high")
        #expect(session.isActive == nil)
    }

    @Test func aFormAnswerIsWrittenInTheFormsOwnTerms() throws {
        let form = try JSONCoding.decoder.decode(
            OC2Form.self,
            from: Data(#"{"id":"frm_1","sessionID":"ses_S","title":"t","fields":[{"key":"lang","type":"string","options":[{"value":"swift","label":"Swift"},{"value":"rust","label":"Rust"}],"custom":true},{"key":"tests","type":"boolean"},{"key":"tags","type":"multiselect","options":[{"value":"a","label":"Alpha"},{"value":"b","label":"Beta"}]},{"key":"count","type":"integer"},{"key":"note","type":"string"}]}"#.utf8))
        let answer = OpenCodeV2Mapping.formAnswer(
            form, answers: [["Rust"], ["No"], ["Alpha", "Beta"], ["3"], ["custom words"]])
        #expect(answer["lang"] == .string("rust"))
        #expect(answer["tests"] == .bool(false))
        #expect(answer["tags"] == .array([.string("a"), .string("b")]))
        #expect(answer["count"] == .number(3))
        #expect(answer["note"] == .string("custom words"))
    }

    @Test func aTypedAnswerNoOptionOffersGoesOutAsTyped() throws {
        let form = try JSONCoding.decoder.decode(
            OC2Form.self,
            from: Data(#"{"id":"frm_1","sessionID":"ses_S","fields":[{"key":"lang","type":"string","options":[{"value":"swift","label":"Swift"}],"custom":true}]}"#.utf8))
        #expect(OpenCodeV2Mapping.formAnswer(form, answers: [["Zig"]])["lang"] == .string("Zig"))
    }

    @Test func anEntryListedFromTheRootIsAbsolute() {
        let entry = OpenCodeV2Mapping.fileNode(OC2FSEntry(path: "home/marcus/Dev/", type: "directory"), root: "/")
        #expect(entry.path == "/home/marcus/Dev")
        #expect(entry.name == "Dev")
        #expect(entry.isDirectory)
    }

    @Test func aDirectoryEntryLosesItsSlashAndKeepsItsKind() {
        let directory = OpenCodeV2Mapping.fileNode(OC2FSEntry(path: "home/", type: "directory"))
        #expect(directory.path == "home")
        #expect(directory.name == "home")
        #expect(directory.isDirectory)
        let file = OpenCodeV2Mapping.fileNode(OC2FSEntry(path: "src/main.swift", type: "file"))
        #expect(file.name == "main.swift")
        #expect(!file.isDirectory)
    }

    @Test func aCatalogModelKeepsItsWindowVariantsAndInputs() throws {
        let model = try JSONCoding.decoder.decode(
            OC2Model.self,
            from: Data(#"{"id":"deepseek-v4.1-flash","modelID":"deepseek-v4.1-flash","providerID":"opencode","name":"DeepSeek V4.1 Flash","capabilities":{"tools":true,"input":["text","image"],"output":["text"]},"variants":[{"id":"max"},{"id":"low"},{"id":"high"}],"status":"active","enabled":true,"limit":{"context":1000000,"output":384000}}"#.utf8))
        let info = OpenCodeV2Mapping.modelInfo(model)
        #expect(info.id == "deepseek-v4.1-flash")
        #expect(info.providerID == "opencode")
        #expect(info.name == "DeepSeek V4.1 Flash")
        #expect(info.variants == ["low", "high", "max"])
        #expect(info.contextWindow == 1_000_000)
        #expect(info.capabilities == ModelCapabilities(attachment: true, imageInput: true, pdfInput: false))
    }

    @Test func aLedgerRecordCountsWhatTheSessionSpent() throws {
        let record = try JSONCoding.decoder.decode(
            OC2Session.self,
            from: Data(#"{"id":"ses_1","projectID":"p","title":"Fix the build","cost":1.25,"tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":30,"write":5}},"time":{"created":1789999000000,"updated":1789999000000},"location":{"directory":"/Users/me/proj"},"model":{"id":"m","providerID":"p"}}"#.utf8))
        let report = OpenCodeLedger.report(
            records: [OpenCodeLedger.Record(record)], days: 30,
            now: Date(timeIntervalSince1970: 1_789_999_500))
        #expect(report.totals.sessions == 1)
        #expect(report.totals.costUSD == 1.25)
        #expect(report.totals.tokens.input == 100)
        #expect(report.totals.tokens.output == 60)
        #expect(report.totals.tokens.cacheRead == 30)
        #expect(report.models.first?.model == "p/m")
        #expect(report.projects.first?.name == "proj")
        #expect(report.records.priciestSession?.title == "Fix the build")
    }

    @Test func aTranscriptPageAfterTheFirstNamesOnlyItsCursor() {
        let first = OpenCodeV2Client.messageQuery(cursor: nil)
        #expect(first.contains(URLQueryItem(name: "order", value: "asc")))
        #expect(!first.contains { $0.name == "cursor" })
        let next = OpenCodeV2Client.messageQuery(cursor: "eyJ")
        #expect(next.contains(URLQueryItem(name: "cursor", value: "eyJ")))
        #expect(!next.contains { $0.name == "order" })
        #expect(next.contains(URLQueryItem(name: "limit", value: "200")))
    }
}
