import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

/// The update route is read by every client ever shipped, so what a newer bridge adds has to be
/// readable by this one without costing it the rest of the answer — and what an older bridge
/// leaves out has to read as absent rather than as a job that never ended.
@Suite struct ServerUpdateJobTests {
    private func decode(_ json: String) throws -> ServerUpdate {
        try BridgeCoding.decoder.decode(ServerUpdate.self, from: Data(json.utf8))
    }

    @Test func aJobIsReadWithItsStepAndOutcome() throws {
        let status = try decode(
            #"""
            {"version":"1.9.2","manager":"systemd","phase":"building",
             "job":{"id":"J1","kind":"update","automatic":true,"step":"build",
                    "from":"1.9.2","target":"1.10.0","startedAt":"2026-09-23T10:00:00Z",
                    "stepStartedAt":"2026-09-23T10:00:20Z"}}
            """#)
        let job = try #require(status.job)
        #expect(job.id == "J1")
        #expect(job.kind == .update)
        #expect(job.automatic)
        #expect(job.step == .build)
        #expect(job.outcome == nil)
        #expect(!job.isFinished)
        #expect(job.target == "1.10.0")
    }

    /// A step or an outcome this client has never heard of is a word it cannot draw, not a reason
    /// to throw away the version, the offer and everything else in the answer.
    @Test func anUnknownWordCostsOnlyItself() throws {
        let status = try decode(
            #"""
            {"version":"2.0.0","manager":"systemd","phase":"idle","updateAvailable":true,
             "job":{"id":"J2","kind":"migrate","step":"verify","outcome":"rolledBack",
                    "finishedAt":"2026-09-23T10:05:00Z"}}
            """#)
        #expect(status.updateAvailable)
        let job = try #require(status.job)
        #expect(job.kind == .update)
        #expect(job.step == nil)
        #expect(job.outcome == nil)
        #expect(job.isFinished)
    }

    @Test func releaseNotesArriveNewestFirst() throws {
        let status = try decode(
            #"""
            {"version":"1.9.2","manager":"systemd","phase":"idle","updateAvailable":true,
             "release":{"version":"1.10.0","commitsPastTag":0,
                        "notes":[{"version":"1.10.0","date":"2026-09-23","items":["One","Two"]},
                                 {"version":null,"items":["Loose"]}]}}
            """#)
        let release = try #require(status.release)
        #expect(release.version == "1.10.0")
        #expect(release.notes.map(\.version) == ["1.10.0", nil])
        #expect(release.notes.first?.items == ["One", "Two"])
    }

    /// Everything a bridge from before jobs sends still reads, with no job and no release.
    @Test func anOlderBridgeHasNeitherJobNorRelease() throws {
        let status = try decode(
            #"{"version":"1.8.0","manager":"manual","phase":"succeeded","updateAvailable":false}"#)
        #expect(status.job == nil)
        #expect(status.release == nil)
        #expect(status.phase == .succeeded)
    }
}
