import Foundation
import Testing

@testable import SetupKit

@Suite struct SetupWireTests {
    @Test func aReportRoundTrips() throws {
        let report = SetupReport(
            capability: SetupCapability.voice, ready: false,
            checks: [
                SetupCheck(id: "voice.gpu", state: .ok, facts: ["name": "RTX PRO 6000", "vramMB": "97887"]),
                SetupCheck(
                    id: "voice.model", state: .todo, facts: ["bytes": "46868000000"],
                    detail: "The voice model is not downloaded",
                    fix: SetupFix(id: "voice.downloadModel", bytes: 46_868_000_000, minutes: 12)),
                SetupCheck(
                    id: "voice.docker", state: .blocked,
                    fix: SetupFix(
                        id: "voice.installDocker", kind: .command,
                        command: "sudo pacman -S docker nvidia-container-toolkit",
                        reason: "needs administrator rights")),
            ],
            job: SetupJob(
                id: "j1", fix: "voice.downloadModel", state: .running, step: "download",
                fraction: 0.25, bytesDone: 11_000_000_000, bytesTotal: 44_000_000_000, startedAt: 12))
        let data = try SetupCodec.encode(report)
        #expect(try SetupCodec.decode(SetupReport.self, from: data) == report)
    }

    @Test func wireShapeIsStable() throws {
        let check = SetupCheck(id: "voice.vram", state: .todo, facts: ["freeMB": "2000", "needMB": "70000"])
        #expect(
            String(decoding: try SetupCodec.encode(check), as: UTF8.self)
                == #"{"facts":{"freeMB":"2000","needMB":"70000"},"id":"voice.vram","state":"todo"}"#)
        let request = SetupFixRequest(fix: "voice.pullImage")
        #expect(
            String(decoding: try SetupCodec.encode(request), as: UTF8.self) == #"{"fix":"voice.pullImage"}"#)
    }

    @Test func aNewerPeerDoesNotBreakAnOlderOne() throws {
        let newer = #"{"id":"x","state":"degraded","facts":{},"future":1}"#
        let check = try SetupCodec.decode(SetupCheck.self, from: Data(newer.utf8))
        #expect(check.state == .blocked)
        let job = #"{"id":"j","fix":"f","state":"paused","facts":{},"startedAt":1}"#
        #expect(try SetupCodec.decode(SetupJob.self, from: Data(job.utf8)).state == .running)
        let fix = #"{"id":"f","kind":"wizard"}"#
        #expect(try SetupCodec.decode(SetupFix.self, from: Data(fix.utf8)).kind == .command)
    }

    @Test func aReportReadsItsFirstOpenCheck() {
        let report = SetupReport(
            capability: "voice", ready: false,
            checks: [SetupCheck(id: "a", state: .ok), SetupCheck(id: "b", state: .todo), SetupCheck(id: "c", state: .todo)])
        #expect(report.firstOpen?.id == "b")
        #expect(SetupReport(capability: "voice", ready: true, checks: [SetupCheck(id: "a", state: .ok)]).firstOpen == nil)
    }

    @Test func settledStates() {
        #expect(SetupJobState.succeeded.isSettled && SetupJobState.failed.isSettled && SetupJobState.cancelled.isSettled)
        #expect(!SetupJobState.running.isSettled && !SetupJobState.queued.isSettled)
        #expect(!SetupState.working.isSettled && SetupState.todo.isSettled)
    }
}
