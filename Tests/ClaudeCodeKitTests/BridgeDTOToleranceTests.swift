import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct BridgeDTOToleranceTests {
    /// Decodes `json` through the same `BridgeCoding.decoder` the backend uses (iso8601 dates).
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BridgeCoding.decoder.decode(type, from: Data(json.utf8))
    }

    private static let fixedTimestamp = "2024-01-02T03:04:05Z"
    private static var fixedDate: Date {
        ISO8601DateFormatter().date(from: fixedTimestamp)!
    }

    @Test func summaryMissingAllOptionalMetadataDecodesToSaneSession() throws {
        let summary = try decode(
            BRSummary.self, #"{"id":"s1","title":"Hello","directory":"/tmp"}"#)
        let session = summary.session

        #expect(session.id == "s1")
        #expect(session.title == "Hello")
        #expect(session.directory == "/tmp")
        #expect(session.agentType == .claudeCode)
        #expect(session.model == nil)
        #expect(session.reasoningEffort == nil)
        #expect(session.isActive == nil)
        #expect(session.createdAt == .distantPast)
        #expect(session.updatedAt == .distantPast)
    }

    @Test func missingTimestampFallbackIsDeterministicAcrossRefreshes() throws {
        let json = #"{"id":"s1b","title":"Hello"}"#
        let first = try decode(BRSummary.self, json).session
        let second = try decode(BRSummary.self, json).session
        #expect(first.createdAt == second.createdAt)
        #expect(first.updatedAt == second.updatedAt)
    }

    @Test func summaryEmptyEffortStringMapsToNil() throws {
        let summary = try decode(BRSummary.self, #"{"id":"s2","title":"t","effort":""}"#)
        #expect(summary.session.reasoningEffort == nil)
    }

    @Test func summaryPresentEffortAndModelMapThrough() throws {
        let summary = try decode(
            BRSummary.self, #"{"id":"s3","title":"t","model":"opus","effort":"high"}"#)
        #expect(summary.session.model == "opus")
        #expect(summary.session.reasoningEffort == "high")
    }

    @Test func summaryCreatedAtFallsBackToUpdatedAtWhenAbsent() throws {
        let summary = try decode(
            BRSummary.self,
            #"{"id":"s4","title":"t","updatedAt":"\#(Self.fixedTimestamp)"}"#)
        let session = summary.session
        #expect(session.createdAt == Self.fixedDate)
        #expect(session.updatedAt == Self.fixedDate)
    }

    @Test func summaryUpdatedAtFallsBackToCreatedAtWhenAbsent() throws {
        let summary = try decode(
            BRSummary.self,
            #"{"id":"s5","title":"t","createdAt":"\#(Self.fixedTimestamp)"}"#)
        let session = summary.session
        #expect(session.updatedAt == Self.fixedDate)
        #expect(session.createdAt == Self.fixedDate)
    }

    @Test func lenientSessionListSurvivesVersionSkewAndDropsMalformedElement() throws {
        let json = """
            [
              {"id":"a","title":"Alpha","model":"opus","effort":"high",
               "createdAt":"\(Self.fixedTimestamp)","updatedAt":"\(Self.fixedTimestamp)","active":true},
              {"id":"b","title":"Beta"},
              {"title":"Gamma has no id"}
            ]
            """
        let sessions = try decode([BRLenient<BRSummary>].self, json)
            .compactMap(\.value).map(\.session)

        #expect(sessions.map(\.id) == ["a", "b"])
        #expect(sessions[0].model == "opus")
        #expect(sessions[0].reasoningEffort == "high")
        #expect(sessions[0].createdAt == Self.fixedDate)
        #expect(sessions[1].model == nil)
        #expect(sessions[1].reasoningEffort == nil)
    }

    @Test func fullSessionMissingMetadataDecodesWithMessagesRequired() throws {
        let session = try decode(
            BRSession.self, #"{"id":"f1","title":"Full","messages":[]}"#)
        let mapped = session.session

        #expect(mapped.id == "f1")
        #expect(mapped.model == nil)
        #expect(mapped.reasoningEffort == nil)
        #expect(mapped.createdAt == .distantPast)
        #expect(mapped.updatedAt == .distantPast)
        #expect(session.messages.isEmpty)
    }

    @Test func fullSessionEmptyEffortMapsToNilAndTimestampFallsBack() throws {
        let session = try decode(
            BRSession.self,
            #"{"id":"f2","title":"Full","effort":"","messages":[],"updatedAt":"\#(Self.fixedTimestamp)"}"#)
        let mapped = session.session
        #expect(mapped.reasoningEffort == nil)
        #expect(mapped.createdAt == Self.fixedDate)
        #expect(mapped.updatedAt == Self.fixedDate)
    }

    @Test func toolUnknownStatusFallsBackToRunning() throws {
        let tool = try decode(
            BRTool.self,
            #"{"id":"t1","name":"Bash","input":"[1,2]","output":"done","status":"who_knows"}"#)
        let call = tool.toolCall

        #expect(call.status == .running)
        #expect(call.name == "Bash")
        #expect(call.output == "done")
        #expect(call.id == "t1")
        #expect(call.input == .array([.integer(1), .integer(2)]))
    }

    @Test func toolKnownStatusMapsThrough() throws {
        let tool = try decode(
            BRTool.self,
            #"{"id":"t2","name":"Read","input":"{}","output":null,"status":"completed"}"#)
        #expect(tool.toolCall.status == .completed)
    }

    @Test func toolInvalidInputJSONYieldsNilInputWithoutThrowing() throws {
        let tool = try decode(
            BRTool.self,
            #"{"id":"t3","name":"Grep","input":"not valid json {","status":"error"}"#)
        let call = tool.toolCall
        #expect(call.input == nil)
        #expect(call.status == .error)
    }

    @Test func partUnknownKindFallsBackToText() throws {
        let part = try decode(BRPart.self, #"{"kind":"totally_unknown","text":"hi"}"#).part
        #expect(part.id == "text")
        #expect(part.kind == .text("hi"))
    }

    @Test func partToolKindWithoutPayloadFallsBackToText() throws {
        let part = try decode(BRPart.self, #"{"kind":"tool"}"#).part
        #expect(part.id == "text")
        #expect(part.kind == .text(""))
    }

    @Test func partReasoningKindMapsThrough() throws {
        let part = try decode(BRPart.self, #"{"kind":"reasoning","text":"thinking"}"#).part
        #expect(part.id == "reasoning")
        #expect(part.kind == .reasoning("thinking"))
    }

    @Test func partToolKindWithPayloadMapsToToolPart() throws {
        let part = try decode(
            BRPart.self,
            #"{"kind":"tool","tool":{"id":"tc9","name":"Bash","input":"{}","status":"running"}}"#
        ).part
        #expect(part.id == "tc9")
        guard case .tool(let call) = part.kind else {
            Issue.record("expected a tool part, got \(part.kind)")
            return
        }
        #expect(call.name == "Bash")
        #expect(call.status == .running)
    }
}
