import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

/// opencode keeps a turn's liveness in memory rather than in the session record, and answers for
/// one workspace at a time. These are the three answers that must stay apart: running, settled,
/// and nobody asked.
@Suite struct OpenCodeLivenessTests {
    private func session(
        _ id: String, directory: String? = "/w", parent: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, agentType: .openCode, title: id, parentID: parent, directory: directory,
            createdAt: Date(), updatedAt: Date())
    }

    private func reading(
        running: [String] = [], scopes: [String] = ["/w"]
    ) -> OpenCodeBackend.LivenessReading {
        var reading = OpenCodeBackend.LivenessReading()
        for scope in scopes {
            reading.absorb(
                Dictionary(
                    uniqueKeysWithValues: running.map { ($0, OCSessionStatus(type: "busy")) }),
                scope: scope)
        }
        return reading
    }

    @Test func aScopeThatAnsweredSettlesEveryRowItCovers() {
        let applied = OpenCodeBackend.applying(
            reading(running: ["a"]), to: [session("a"), session("b")])

        #expect(applied[0].isActive == true)
        #expect(applied[1].isActive == false)
    }

    @Test func aScopeNobodyAskedLeavesItsRowsUnknown() {
        let applied = OpenCodeBackend.applying(
            reading(running: ["a"], scopes: ["/w"]),
            to: [session("a"), session("elsewhere", directory: "/other")])

        #expect(applied[0].isActive == true)
        #expect(applied[1].isActive == nil)
    }

    @Test func nothingAskedAtAllChangesNothing() {
        let applied = OpenCodeBackend.applying(
            OpenCodeBackend.LivenessReading(), to: [session("a")])

        #expect(applied[0].isActive == nil)
    }

    @Test func anEmptyAnswerIsSettledRatherThanUnknown() {
        let applied = OpenCodeBackend.applying(reading(running: []), to: [session("a")])

        #expect(applied[0].isActive == false)
    }

    @Test func aTurnWaitingOnTheProviderIsStillATurn() {
        #expect(OpenCodeMapping.isRunning(OCSessionStatus(type: "retry")))
        #expect(OpenCodeMapping.isRunning(OCSessionStatus(type: "busy")))
        #expect(!OpenCodeMapping.isRunning(OCSessionStatus(type: "idle")))
    }

    @Test func busyChildrenAreCountedOntoTheParentThatSpawnedThem() {
        let applied = OpenCodeBackend.applying(
            reading(running: ["kid1", "kid2"]),
            to: [
                session("boss"), session("kid1", parent: "boss"),
                session("kid2", parent: "boss"), session("kid3", parent: "boss"),
            ])

        let boss = applied.first { $0.id == "boss" }
        #expect(boss?.activeAgents == 2)
        #expect(boss?.isWorking == true)
    }

    /// A subagent's own transcript is one turn long, so recency is a fair guess about it — but only
    /// where the server could not be asked. An answer always outranks the clock.
    @Test func aSubagentPrefersTheServersAnswerToTheClock() throws {
        let json = """
            {"id":"kid","title":"t","parentID":"boss","directory":"/w",
             "time":{"created":0,"updated":0}}
            """
        let raw = try JSONDecoder().decode(OCSession.self, from: Data(json.utf8))

        #expect(OpenCodeMapping.subagent(raw, running: ["kid"]).isActive)
        #expect(!OpenCodeMapping.subagent(raw, running: []).isActive)
        #expect(!OpenCodeMapping.subagent(raw, running: nil).isActive)
    }
}
