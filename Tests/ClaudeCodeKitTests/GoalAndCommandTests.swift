import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct GoalDecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BridgeCoding.decoder.decode(type, from: Data(json.utf8))
    }

    @Test func setGoalIsActive() throws {
        let goal = try decode(
            BRGoal.self,
            #"{"condition":"the tests pass","met":false,"updatedAt":"2024-01-02T03:04:05Z"}"#
        ).goal

        #expect(goal.condition == "the tests pass")
        #expect(goal.isActive)
        #expect(!goal.isMet)
        #expect(goal.reason == nil)
    }

    /// The CLI records a cleared goal exactly like an achieved one (`met: true`), so both must
    /// stop the client presenting the agent as still working.
    @Test func metGoalIsNotActiveAndCarriesItsVerdict() throws {
        let goal = try decode(
            BRGoal.self,
            """
            {"condition":"the tests pass","met":true,"reason":"suite green",
             "iterations":3,"durationMs":9802,"tokens":418}
            """
        ).goal

        #expect(!goal.isActive)
        #expect(goal.reason == "suite green")
        #expect(goal.iterations == 3)
        #expect(goal.tokens == 418)
        #expect(goal.duration == 9.802)
    }

    @Test func failedGoalIsNotActive() throws {
        let goal = try decode(
            BRGoal.self, #"{"condition":"ship it","met":false,"failed":true}"#
        ).goal

        #expect(!goal.isActive)
        #expect(goal.didFail)
    }

    /// A bridge too old to report goals omits the field entirely; that must decode, not throw.
    @Test func sessionWithoutGoalDecodes() throws {
        let session = try decode(
            BRSession.self,
            #"{"id":"s1","title":"t","messages":[],"directory":null}"#)

        #expect(session.goal == nil)
    }

    @Test func goalEventCarriesTheGoalAndAnEmptyOneClearsIt() {
        var decoder = BridgeEventDecoder()

        let set = decoder.decode(
            SSEvent(
                id: nil, type: nil,
                data: #"{"type":"goal","goal":{"condition":"the tests pass","met":false}}"#))
        guard case .goal(let goal) = set else {
            Issue.record("expected a goal event, got \(String(describing: set))")
            return
        }
        #expect(goal?.condition == "the tests pass")
        #expect(goal?.isActive == true)

        let cleared = decoder.decode(SSEvent(id: nil, type: nil, data: #"{"type":"goal"}"#))
        guard case .goal(let none) = cleared else {
            Issue.record("expected a goal event, got \(String(describing: cleared))")
            return
        }
        #expect(none == nil)
    }
}

@Suite struct AgentCommandTests {
    @Test func invocationJoinsNameAndArguments() {
        let goal = AgentCommand(name: "goal", details: "", source: .builtin)

        #expect(goal.invocation(arguments: "the tests pass") == "/goal the tests pass")
        #expect(goal.invocation(arguments: "  spaced  ") == "/goal spaced")
        #expect(goal.invocation(arguments: "") == "/goal")
        #expect(goal.invocation(arguments: nil) == "/goal")
    }

    @Test func takesArgumentsFollowsTheHint() {
        #expect(
            AgentCommand(
                name: "goal", details: "", argumentHint: "<condition> | clear", source: .builtin
            ).takesArguments)
        #expect(!AgentCommand(name: "recap", details: "", source: .builtin).takesArguments)
        #expect(
            !AgentCommand(name: "recap", details: "", argumentHint: "", source: .builtin)
                .takesArguments)
    }

    @Test func catalogDecodesFromTheBridgeShape() throws {
        let commands = try BridgeCoding.decoder.decode(
            [AgentCommand].self,
            from: Data(
                """
                [{"name":"goal","description":"Keep working until a condition is met",
                  "argumentHint":"<condition> | clear","source":"builtin"},
                 {"name":"cloudflare:build-mcp","description":"Build an MCP server",
                  "source":"plugin","scope":"cloudflare"}]
                """.utf8))

        #expect(commands.count == 2)
        #expect(commands[0].source == .builtin)
        #expect(commands[0].details == "Keep working until a condition is met")
        #expect(commands[1].source == .plugin)
        #expect(commands[1].scope == "cloudflare")
    }

    /// A server that classifies a command in a way this client predates must not fail the decode
    /// of the whole catalog.
    @Test func unknownSourceFallsBackToCustom() throws {
        let command = try BridgeCoding.decoder.decode(
            AgentCommand.self,
            from: Data(#"{"name":"weird","description":"d","source":"from-the-future"}"#.utf8))

        #expect(command.source == .custom)
    }

    @Test func missingDescriptionDecodesToEmptyRatherThanThrowing() throws {
        let command = try BridgeCoding.decoder.decode(
            AgentCommand.self, from: Data(#"{"name":"bare","source":"user"}"#.utf8))

        #expect(command.details.isEmpty)
        #expect(command.source == .user)
    }
}
