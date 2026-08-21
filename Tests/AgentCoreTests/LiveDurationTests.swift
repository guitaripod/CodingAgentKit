import AgentCore
import Foundation
import Testing

private func session(_ id: String, host: String, updated: Date, active: Bool) -> AgentSession {
    var value = AgentSession(
        id: id, agentType: .openCode, title: id, createdAt: updated, updatedAt: updated,
        isActive: active)
    value.hostID = host
    return value
}

private func snapshot(_ readings: [HostReading], _ sessions: [AgentSession]) -> FederatedSnapshot {
    FederatedSnapshot(readings: readings, sessions: sessions)
}

@Suite struct LiveDurationTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    @Test func aRunningSessionOnALiveHostTicks() {
        let running = session("a", host: "arch", updated: epoch, active: true)
        let snap = snapshot([HostReading(hostID: "arch", state: .live, observedAt: epoch)], [running])
        let duration = LiveDuration.of(running, in: snap, now: epoch.addingTimeInterval(72))
        #expect(duration.isTicking)
        #expect(duration.seconds == 72)
        #expect(duration.elapsedText == "1m 12s")
    }

    @Test func aRunningSessionOnAStaleHostFreezesAtTheLastReading() {
        let running = session("a", host: "macbook", updated: epoch, active: true)
        let snap = snapshot(
            [HostReading(hostID: "macbook", state: .stale("asleep"), observedAt: epoch.addingTimeInterval(30))],
            [running])
        let duration = LiveDuration.of(running, in: snap, now: epoch.addingTimeInterval(4 * 3600))
        #expect(!duration.isTicking)
        #expect(duration.seconds == 30)
        #expect(duration.elapsedText == "30s")
    }

    @Test func aStaleHostThatNeverAnsweredKnowsNothing() {
        let running = session("a", host: "macbook", updated: epoch, active: true)
        let snap = snapshot(
            [HostReading(hostID: "macbook", state: .unknown("never read"), observedAt: nil)], [running])
        #expect(LiveDuration.of(running, in: snap, now: epoch) == .unknown)
        #expect(LiveDuration.of(running, in: snap, now: epoch).seconds == nil)
        #expect(LiveDuration.of(running, in: snap, now: epoch).elapsedText == nil)
    }

    @Test func anIdleSessionReportsLastActivityAndNeverTicks() {
        let idle = session("a", host: "arch", updated: epoch, active: false)
        let snap = snapshot([HostReading(hostID: "arch", state: .live, observedAt: epoch)], [idle])
        let duration = LiveDuration.of(idle, in: snap, now: epoch.addingTimeInterval(900))
        #expect(duration == .idle(lastActivity: epoch))
        #expect(!duration.isTicking)
        #expect(duration.elapsedText == nil)
    }

    @Test func clockSkewClampsToZeroInsteadOfCountingBackwards() {
        let future = epoch.addingTimeInterval(5)
        let running = session("a", host: "macbook", updated: future, active: true)
        let snap = snapshot([HostReading(hostID: "macbook", state: .live, observedAt: epoch)], [running])
        let duration = LiveDuration.of(running, in: snap, now: epoch)
        #expect(duration.seconds == 0)
        #expect(duration.elapsedText == "0s")
    }

    @Test func subagentWorkCountsAsRunningEvenWhenTheSessionIsQuiet() {
        var delegating = session("a", host: "arch", updated: epoch, active: false)
        delegating.activeAgents = 3
        let snap = snapshot([HostReading(hostID: "arch", state: .live, observedAt: epoch)], [delegating])
        let duration = LiveDuration.of(delegating, in: snap, now: epoch.addingTimeInterval(10))
        #expect(duration.isTicking)
        #expect(duration.seconds == 10)
    }

    @Test func aTurnStartBeatsTheSessionStampWhenTheBackendReportsOne() {
        let running = session("a", host: "arch", updated: epoch.addingTimeInterval(50), active: true)
        let snap = snapshot([HostReading(hostID: "arch", state: .live, observedAt: epoch)], [running])
        let duration = LiveDuration.of(
            running, in: snap, startedAt: epoch, now: epoch.addingTimeInterval(120))
        #expect(duration.seconds == 120)
    }

    @Test func aSessionWithNoHostMeasuresAgainstNow() {
        let direct = AgentSession(
            id: "a", agentType: .openCode, title: "a", createdAt: epoch, updatedAt: epoch,
            isActive: true)
        let snap = snapshot([], [direct])
        let duration = LiveDuration.of(direct, in: snap, now: epoch.addingTimeInterval(45))
        #expect(duration.isTicking)
        #expect(duration.seconds == 45)
    }

    @Test func elapsedTextScalesWithoutSecondsPastAnHour() {
        let base = LiveDuration.running(since: epoch, measuredAt: epoch.addingTimeInterval(9))
        #expect(base.elapsedText == "9s")
        #expect(LiveDuration.running(since: epoch, measuredAt: epoch.addingTimeInterval(65)).elapsedText == "1m 05s")
        #expect(LiveDuration.running(since: epoch, measuredAt: epoch.addingTimeInterval(3600)).elapsedText == "1h 00m")
        #expect(LiveDuration.running(since: epoch, measuredAt: epoch.addingTimeInterval(7_500)).elapsedText == "2h 05m")
    }
}
