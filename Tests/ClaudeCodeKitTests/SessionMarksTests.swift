import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct SessionMarksTests {
    private func summary(_ json: String) throws -> AgentSession {
        try BridgeCoding.decoder.decode(BRSummary.self, from: Data(json.utf8))
            .session(agentType: .claudeCode)
    }

    private let stamp = "2026-10-10T12:00:00Z"

    @Test func aBridgeThatSpeaksMarksReportsAllOfThem() throws {
        let session = try summary(
            #"""
            {"id":"s1","title":"t","updatedAt":"\#(stamp)","saved":true,"pinned":true,
             "pinnedAt":"\#(stamp)","archived":false,"readAt":"\#(stamp)"}
            """#)
        #expect(session.saved == true)
        #expect(session.pinned == true)
        #expect(session.pinnedAt == ISO8601DateFormatter().date(from: stamp))
        #expect(session.archived == false)
        #expect(session.readAt == ISO8601DateFormatter().date(from: stamp))
        #expect(session.reportsMarks)
    }

    @Test func aBridgeThatNeverHeardOfMarksSaysNothingAndIsNotReadAsSayingNo() throws {
        let session = try summary(#"{"id":"s1","title":"t","updatedAt":"\#(stamp)","saved":false}"#)
        #expect(session.pinned == nil)
        #expect(session.archived == nil)
        #expect(session.readAt == nil)
        #expect(!session.reportsMarks)
    }

    @Test func aChatNobodyHasMarkedHasNoReadTimeButStillSpeaksMarks() throws {
        let session = try summary(
            #"{"id":"s1","title":"t","updatedAt":"\#(stamp)","pinned":false,"archived":false}"#)
        #expect(session.readAt == nil)
        #expect(session.reportsMarks)
    }

    @Test func aPatchNamesOnlyWhatThePressChanged() throws {
        let change = SessionMarkChange(
            pinned: true, read: .seen, at: ISO8601DateFormatter().date(from: stamp)!)
        let body = try BridgeCoding.encoder.encode(
            BRPatch(
                title: nil, saved: change.saved, pinned: change.pinned, archived: change.archived,
                read: change.read?.rawValue, at: change.at))
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["pinned", "read", "at"])
        #expect(object["pinned"] as? Bool == true)
        #expect(object["read"] as? String == "seen")
        #expect(object["at"] as? String == stamp)
    }

    @Test func aChangeThatNamesNothingIsEmpty() {
        #expect(SessionMarkChange().isEmpty)
        #expect(!SessionMarkChange(archived: false).isEmpty)
    }

    @Test func theBridgeBackendClaimsMarks() {
        let backend = ClaudeCodeBackend(
            config: ServerConfig(baseURL: URL(string: "http://127.0.0.1:1")!))
        #expect(backend.capabilities.supportsSessionMarks)
    }
}
