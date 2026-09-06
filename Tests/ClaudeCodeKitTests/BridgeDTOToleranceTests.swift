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

    /// A call that handed its work to the background answers in milliseconds and the work runs for
    /// minutes, so the ending arrives long afterwards as its own field. A client that cannot read
    /// it is a client holding a launch with no record that anything ever stopped.
    @Test func aToolCarriesHowItsBackgroundWorkEnded() throws {
        let tool = try decode(
            BRTool.self,
            #"""
            {"id":"toolu_01","name":"Workflow","input":"{}","output":"launched","status":"completed",
             "background":{"taskID":"w2cxy65y7","status":"stopped","summary":"no record",
             "reportedAt":"\#(Self.fixedTimestamp)"}}
            """#
        ).toolCall

        #expect(tool.background?.status == .stopped)
        #expect(tool.background?.taskID == "w2cxy65y7")
        #expect(tool.background?.result == nil)
        #expect(tool.background?.summary == "no record")
        #expect(tool.background?.reportedAt == Self.fixedDate)
        #expect(tool.background?.isSuccess == false)
        #expect(tool.background?.answer == "no record")
    }

    @Test func anOrdinaryToolHasNoBackgroundEnding() throws {
        let tool = try decode(
            BRTool.self, #"{"id":"t","name":"Bash","input":"{}","status":"completed"}"#).toolCall

        #expect(tool.background == nil)
    }

    /// A status word a newer bridge invents must never read as success — an ending nobody
    /// recognises is still an ending, and calling it done would fold a wrong answer into a card.
    @Test func anUnknownBackgroundStatusIsNotSuccess() throws {
        let tool = try decode(
            BRTool.self,
            #"{"id":"t","name":"Workflow","input":"{}","status":"completed","background":{"status":"exploded"}}"#
        ).toolCall

        #expect(tool.background?.status == .failed)
        #expect(tool.background?.isSuccess == false)
    }

    @Test func summaryCarryingBackgroundWorkNamesItAndAnIdleOneHasNone() throws {
        let carrying = try decode(
            BRSummary.self,
            #"{"id":"s1","title":"t","active":false,"backgroundTasks":1,"backgroundTask":"sleep 60"}"#
        ).session(agentType: .claudeCode)
        #expect(carrying.isActive == false)
        #expect(carrying.backgroundWork == BackgroundWork(tasks: 1, task: "sleep 60"))
        let idle = try decode(BRSummary.self, #"{"id":"s1","title":"t","active":false}"#)
            .session(agentType: .claudeCode)
        #expect(idle.backgroundWork == nil)
    }

    @Test func summaryMissingAllOptionalMetadataDecodesToSaneSession() throws {
        let summary = try decode(
            BRSummary.self, #"{"id":"s1","title":"Hello","directory":"/tmp"}"#)
        let session = summary.session(agentType: .claudeCode)

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
        let first = try decode(BRSummary.self, json).session(agentType: .claudeCode)
        let second = try decode(BRSummary.self, json).session(agentType: .claudeCode)
        #expect(first.createdAt == second.createdAt)
        #expect(first.updatedAt == second.updatedAt)
    }

    @Test func summaryEmptyEffortStringMapsToNil() throws {
        let summary = try decode(BRSummary.self, #"{"id":"s2","title":"t","effort":""}"#)
        #expect(summary.session(agentType: .claudeCode).reasoningEffort == nil)
    }

    @Test func summaryPresentEffortAndModelMapThrough() throws {
        let summary = try decode(
            BRSummary.self, #"{"id":"s3","title":"t","model":"opus","effort":"high"}"#)
        #expect(summary.session(agentType: .claudeCode).model == "opus")
        #expect(summary.session(agentType: .claudeCode).reasoningEffort == "high")
    }

    @Test func summaryCreatedAtFallsBackToUpdatedAtWhenAbsent() throws {
        let summary = try decode(
            BRSummary.self,
            #"{"id":"s4","title":"t","updatedAt":"\#(Self.fixedTimestamp)"}"#)
        let session = summary.session(agentType: .claudeCode)
        #expect(session.createdAt == Self.fixedDate)
        #expect(session.updatedAt == Self.fixedDate)
    }

    @Test func summaryUpdatedAtFallsBackToCreatedAtWhenAbsent() throws {
        let summary = try decode(
            BRSummary.self,
            #"{"id":"s5","title":"t","createdAt":"\#(Self.fixedTimestamp)"}"#)
        let session = summary.session(agentType: .claudeCode)
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
            .compactMap(\.value).map { $0.session(agentType: .claudeCode) }

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
        let mapped = session.session(agentType: .claudeCode)

        #expect(mapped.id == "f1")
        #expect(mapped.model == nil)
        #expect(mapped.reasoningEffort == nil)
        #expect(mapped.createdAt == .distantPast)
        #expect(mapped.updatedAt == .distantPast)
        #expect(session.messages.isEmpty)
    }

    @Test func aModelRowCarriesTheCatalogsWindow() throws {
        let model = try decode(
            BRRemoteModel.self,
            #"{"id":"ollama-cloud/glm-5.3-flash","name":"GLM 5.3 Flash","provider":"ollama-cloud","contextWindow":1048576}"#
        )
        #expect(model.contextWindow == 1_048_576)
    }

    /// A bridge older than the field says nothing, and a client then sizes the ring against what
    /// the model's name is known to hold — so the field must read as absent, not as zero.
    @Test func anOldBridgeLeavesTheModelWindowUnknown() throws {
        let model = try decode(
            BRRemoteModel.self,
            #"{"id":"anthropic/fable","name":"Fable","provider":"anthropic"}"#
        )
        #expect(model.contextWindow == nil)
    }

    @Test func fullSessionEmptyEffortMapsToNilAndTimestampFallsBack() throws {
        let session = try decode(
            BRSession.self,
            #"{"id":"f2","title":"Full","effort":"","messages":[],"updatedAt":"\#(Self.fixedTimestamp)"}"#)
        let mapped = session.session(agentType: .claudeCode)
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

@Suite struct BridgeContextFootprintTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BridgeCoding.decoder.decode(type, from: Data(json.utf8))
    }

    /// The footprint is the turn's last call; the bill is every call. A bridge too old to send the
    /// footprint leaves it nil rather than letting the bill stand in for it.
    @Test func aMessageCarriesItsFootprintApartFromItsBill() throws {
        let message = try decode(
            BRMessage.self,
            #"""
            {"id":"m1","role":"assistant","parts":[],"createdAt":"2024-01-02T03:04:05Z",
             "usage":{"input":130,"output":1000,"cacheRead":82000,"cacheWrite5m":2000},
             "context":{"input":10,"output":700,"cacheRead":42000}}
            """#
        ).chat(agentType: .claudeCode)
        #expect(message.usage?.cacheRead == 82_000)
        #expect(message.context?.cacheRead == 42_000)
        #expect(message.context?.total == 42_710)
    }

    @Test func anOldBridgeLeavesTheFootprintUnknown() throws {
        let message = try decode(
            BRMessage.self,
            #"""
            {"id":"m1","role":"assistant","parts":[],"createdAt":"2024-01-02T03:04:05Z",
             "usage":{"input":130,"output":1000,"cacheRead":82000}}
            """#
        ).chat(agentType: .claudeCode)
        #expect(message.usage != nil)
        #expect(message.context == nil)
    }
}
