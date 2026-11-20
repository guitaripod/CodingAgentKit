import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

/// The expert payloads in the shape claude-bridge writes them (sorted keys, ISO 8601 dates), with
/// a few fields from a later bridge this client does not know, which must be read past.
@Suite struct ExpertWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BridgeCoding.decoder.decode(type, from: Data(json.utf8))
    }

    private static let experts = """
        [{"bench":[{"checkedAt":"2026-11-20T12:02:00Z","facts":{"model":"iPad Pro (11-inch) (3rd generation)","osVersion":"27.3","transport":"wired"},"id":"B1","identifier":"00008103-0019349C0ED0801E","kind":"appleDevice","lock":"/tmp/ipad-pro-m1.lock","name":"iPad Pro M1","state":"held","holder":{"sessionID":"S1","title":"Unrager posts","pid":4242}},{"id":"B2","kind":"teleporter","name":"Future thing","state":"warp"}],
          "briefTokens":3104,"charter":"Measure on the real iPads.","createdAt":"2026-11-20T10:00:00Z","directory":"/Users/marcus/Dev","effort":"high",
          "glyph":"iP","guardNext":"2026-11-21T01:00:00Z","guardRule":{"hour":3,"kind":"daily","minute":0},
          "guards":[{"command":"xcodebuild test","history":[{"at":"2026-11-20T01:00:00Z","exitCode":65,"failure":"exit","output":"2 failed","passed":false,"seconds":41.2},{"at":"2026-11-19T01:00:00Z","failure":"exit","passed":false,"seconds":40},{"at":"2026-11-18T01:00:00Z","passed":true,"seconds":39}],"id":"G1","last":{"at":"2026-11-20T01:00:00Z","exitCode":65,"failure":"exit","output":"2 failed","passed":false,"seconds":41.2},"name":"PadLayoutTests"},{"command":"bench","id":"G2","metric":{"atMost":100,"pattern":"first frame ([0-9.]+) ms","unit":"ms"},"name":"Resize","running":true}],
          "hue":"blue","id":"E1","journal":[{"at":"2026-11-20T11:00:00Z","commits":["70829b0 feat(ios): open a post"],"id":"J1","measured":["280 tests"],"outcome":"Posts zoom.","sessionID":"S0","title":"Unrager posts"}],
          "model":"opus","name":"iPadOS","notebook":{"adopted":true,"notes":23,"path":"/Users/marcus/claudememory/tailscode","retired":4,"stale":2},"notebookPath":"/Users/marcus/claudememory/tailscode",
          "pending":3,"purpose":"Makes the apps excellent on iPad.","skills":["ipados","ios-dev"],
          "task":{"active":true,"sessionID":"S1","title":"Unrager posts","updatedAt":"2026-11-20T12:01:00Z"},
          "tasks":[{"active":true,"sessionID":"S1","title":"Unrager posts","updatedAt":"2026-11-20T12:01:00Z"},{"active":false,"debrief":"open","sessionID":"S0","title":"Performance round","updatedAt":"2026-11-19T12:00:00Z"},{"active":false,"debrief":"hovering","sessionID":"S9","title":"From the future","updatedAt":"2026-11-18T12:00:00Z"}],
          "timeZone":"Europe/Helsinki","updatedAt":"2026-11-20T10:00:00Z","watches":["W1"],"somethingNew":{"x":1}},
         {"id":"broken"}]
        """

    private static let debrief = """
        {"at":"2026-11-20T12:30:00Z","coveredTurns":4,"expertID":"E1","journal":{"at":"2026-11-20T12:30:00Z","commits":[],"id":"J2","measured":[],"outcome":"Done.","sessionID":"S1","title":"Unrager posts"},
         "proposals":[{"body":"Fact.","id":"P1","op":"add","reason":"Shown today.","state":"pending","summary":"s","title":"Open natively"},{"body":"","id":"P2","note":"column.md","op":"retire","reason":"Replaced.","state":"accepted","summary":"","title":"Column"}],
         "sessionID":"S1","state":"open"}
        """

    @Test func expertsDecodeAsTheBridgeWritesThemAndAnUnreadableOneIsLeftOut() throws {
        let decoded = try decode([BRLenient<MachineExpert>].self, Self.experts).compactMap(\.value)
        #expect(decoded.map(\.id) == ["E1"])
        let expert = try #require(decoded.first)
        #expect(expert.bench.count == 2)
        #expect(expert.bench[0].state == .held)
        #expect(expert.bench[0].holder?.title == "Unrager posts")
        #expect(expert.bench[0].facts?["transport"] == "wired")
        #expect(expert.bench[1].kind == .command)
        #expect(expert.bench[1].state == nil)
        #expect(expert.guardRule == ScheduleRule(kind: .daily, hour: 3, minute: 0))
        #expect(expert.guards[0].isFailing)
        #expect(expert.guards[0].last?.failure == .exit)
        #expect(expert.guards[0].failingSince == ISO8601DateFormatter().date(from: "2026-11-19T01:00:00Z"))
        #expect(expert.guards[1].metric?.atMost == 100)
        #expect(expert.runningGuards)
        #expect(expert.failingGuards.map(\.name) == ["PadLayoutTests"])
        #expect(expert.notebook.adopted && expert.notebook.notes == 23)
        #expect(expert.task?.sessionID == "S1")
        #expect(expert.tasks.map(\.debrief) == [nil, .open, nil])
        #expect(expert.pending == 3)
        #expect(expert.journal.first?.commits == ["70829b0 feat(ios): open a post"])
    }

    @Test func aDebriefDecodesWithItsProposals() throws {
        let debrief = try decode(ExpertDebrief.self, Self.debrief)
        #expect(debrief.state == .open)
        #expect(debrief.proposals.map(\.op) == [.add, .retire])
        #expect(debrief.pending.map(\.id) == ["P1"])
        #expect(debrief.journal?.title == "Unrager posts")
    }

    @Test func aChangeSendsOnlyDescriptionsNeverWhatAProofFound() throws {
        let item = ExpertBenchItem(
            id: "B1", name: "iPad", kind: .appleDevice, identifier: "X", state: .ready, facts: ["model": "iPad"],
            checkedAt: Date())
        let change = ExpertChange(bench: [item])
        let json = String(decoding: try BridgeCoding.encoder.encode(change), as: UTF8.self)
        #expect(json.contains("\"identifier\":\"X\""))
        #expect(!json.contains("facts"))
        #expect(!json.contains("checkedAt"))
        #expect(!json.contains("\"state\""))
    }

    @Test func aSessionNamesItsExpert() throws {
        let row = try decode(
            BRSummary.self,
            #"{"id":"S1","title":"Unrager posts","model":"opus","effort":"high","createdAt":"2026-11-20T12:00:00Z","updatedAt":"2026-11-20T12:00:00Z","expert":"E1"}"#)
        #expect(row.session(agentType: .claudeCode).expertID == "E1")
    }

    @Test func aNoteSaysWhichTaskWroteIt() {
        let note = ExpertNote(id: "a.md", title: "A", summary: "", source: "tailscode-expert:E1:S1")
        #expect(note.sourceSession == "S1")
        #expect(ExpertNote(id: "b.md", title: "B", summary: "", source: "tailscode-expert:E1:made").sourceSession == nil)
    }
}
