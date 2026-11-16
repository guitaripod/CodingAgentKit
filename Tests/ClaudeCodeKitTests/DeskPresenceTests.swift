import AgentCore
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import ClaudeCodeKit

@Suite(.serialized) struct DeskPresenceTests {
    private static func backend() -> ClaudeCodeBackend {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WaitBridgeProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let config = ServerConfig(baseURL: URL(string: "http://desks.test:4098")!)
        return ClaudeCodeBackend(config: config, agentType: .claudeCode, http: http)
    }

    private static func desk(
        _ id: String, idle: Int?, locked: Bool = false, heard: Int = 5
    ) -> DeskPresence.Desk {
        DeskPresence.Desk(desk: id, name: id, idle: idle, locked: locked, heard: heard)
    }

    @Test func aBridgeThatKeepsDesksTakesTheReport() async throws {
        WaitBridge.shared.publish(200, #"{"ok":true}"#, at: "/presence")
        let report = DeskReport(desk: "d1", name: "arch", idle: 4, looked: ["s1"])
        #expect(try await Self.backend().reportDesk(report))
    }

    @Test func aBridgeFromBeforeDesksIsNotAFailure() async throws {
        WaitBridge.shared.publish(404, nil, at: "/presence")
        let report = DeskReport(desk: "d1", name: "arch", idle: 4)
        #expect(try await Self.backend().reportDesk(report) == false)
        #expect(try await Self.backend().deskPresence() == nil)
    }

    @Test func anAnswerReadsDesksAndLooksWithOrWithoutFractionalSeconds() async throws {
        WaitBridge.shared.publish(
            200,
            #"{"desks":[{"desk":"d1","name":"arch","idle":12,"locked":false,"heard":3}],"looked":{"s1":"2026-11-16T12:00:00Z","s2":"2026-11-16T12:00:00.250Z","s3":"later"},"extra":1}"#,
            at: "/presence")
        let presence = try #require(try await Self.backend().deskPresence())
        #expect(presence.desks == [DeskPresence.Desk(desk: "d1", name: "arch", idle: 12, locked: false, heard: 3)])
        #expect(Set(presence.looked.keys) == ["s1", "s2"])
        #expect(presence.away == nil)
    }

    @Test func theWaitIsAPlainGetCarryingThePatience() async throws {
        let wait = try #require(try await Self.backend().deskAwayRequest(awayAfter: 120))
        #expect(wait.request.httpMethod == "GET")
        #expect(wait.request.url?.path == "/presence/wait")
        #expect(wait.request.url?.query == "awayAfter=120")
        #expect(wait.uploadsEmptyBody == false)
    }

    @Test func aHeldAnswerReadsPastTheHeartbeats() throws {
        let lenient = try DeskPresence.decode(
            status: 200, body: Data(#"{"desks":[],"looked":{"a":"2026-11-16T12:00:00Z","b":null,"c":3}}"#.utf8))
        #expect(Array(lenient.looked.keys) == ["a"], "one look a newer server wrote oddly costs only itself")
        let second = Date(timeIntervalSince1970: 1_800_000_000)
        let sameSecond = DeskPresence(looked: ["s": second])
        #expect(sameSecond.looked(at: "s", since: second.addingTimeInterval(0.4)))
        #expect(!sameSecond.looked(at: "s", since: second.addingTimeInterval(1.2)))
        let body = Data("\n\n\n{\"desks\":[],\"looked\":{},\"away\":true}".utf8)
        let presence = try DeskPresence.decode(status: 200, body: body)
        #expect(presence.away == true)
        #expect(throws: AgentError.self) { try DeskPresence.decode(status: 502, body: Data()) }
    }

    @Test func thePersonIsAtTheFreshestUnlockedRecentlyUsedDesk() {
        let presence = DeskPresence(desks: [
            Self.desk("idle", idle: 400),
            Self.desk("locked", idle: 1, locked: true),
            Self.desk("silent", idle: 2, heard: 120),
            Self.desk("blind", idle: nil),
            Self.desk("used", idle: 30),
            Self.desk("busiest", idle: 3),
        ])
        #expect(presence.occupied(awayAfter: 120)?.desk == "busiest")
        #expect(presence.occupied(awayAfter: 2) == nil)
        #expect(DeskPresence(desks: [Self.desk("idle", idle: 400)]).occupied(awayAfter: 600)?.desk == "idle")
    }

    @Test func severalServersMergeByTheFreshestReportAndTheLatestLook() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        let merged = DeskPresence.merged([
            DeskPresence(desks: [Self.desk("d1", idle: 50, heard: 40)], looked: ["s1": late]),
            DeskPresence(
                desks: [Self.desk("d1", idle: 2, heard: 1), Self.desk("d2", idle: 9)],
                looked: ["s1": early, "s2": early], away: true),
        ])
        #expect(merged.desks.map(\.desk) == ["d1", "d2"])
        #expect(merged.desks.first?.idle == 2)
        #expect(merged.looked == ["s1": late, "s2": early])
        #expect(merged.looked(at: "s1", since: late))
        #expect(!merged.looked(at: "s2", since: late))
        #expect(merged.away == true)
    }

    @Test func aHeldNoticeIsTakenOnlyWhenTheBridgeSaysSo() async throws {
        let notice = DeskHeldNotice(
            token: "ab", identifier: "done:s1", title: "Fix", body: "Done", sessionID: "s1",
            userInfo: #"{"sessionID":"s1"}"#)
        WaitBridge.shared.publish(200, #"{"ok":true,"held":true}"#, at: "/push/hold")
        #expect(try await Self.backend().holdNotice(notice))
        WaitBridge.shared.publish(200, #"{"ok":true,"held":false}"#, at: "/push/hold")
        #expect(try await Self.backend().holdNotice(notice) == false)
        WaitBridge.shared.publish(404, nil, at: "/push/hold")
        #expect(try await Self.backend().holdNotice(notice) == false)
    }

    @Test func rulesCarryTheDeskWishOnlyWhenGiven() throws {
        let plain = try String(
            data: BridgeCoding.encoder.encode(DevicePushRules(finish: "settled")), encoding: .utf8)
        #expect(plain?.contains("quietAtDesk") == false)
        let quiet = DevicePushRules(finish: "settled", quietAtDesk: true, awayAfter: 120)
        let data = try BridgeCoding.encoder.encode(quiet)
        #expect(try BridgeCoding.decoder.decode(DevicePushRules.self, from: data) == quiet)
    }
}
