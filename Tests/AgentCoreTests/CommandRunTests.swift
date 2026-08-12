import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

/// A command is a turn, so it has to leave carrying what a typed message would. These prove the
/// two roads out — the backend that has a command endpoint, and the fallback that sends the
/// command as prompt text — both keep the model, the effort and the agent.
@Suite struct CommandRunTests {
    private let command = AgentCommand(name: "review", details: "", source: .custom)

    @Test func promptTextFallbackCarriesTheWholePick() async throws {
        let backend = MockBackend(agentType: .claudeCode)
        let conversation = AgentConversation(backend: backend, sessionID: "s")

        try await conversation.run(
            command, arguments: "the diff",
            model: ModelSelection(providerID: "anthropic", modelID: "claude-opus-5"),
            reasoningEffort: "xhigh", agent: "reviewer")

        let sent = try #require(backend.recordedPrompts.last)
        #expect(sent.text == "/review the diff")
        #expect(sent.model?.modelID == "claude-opus-5")
        #expect(sent.reasoningEffort == "xhigh")
        #expect(sent.agent == "reviewer")
    }

    @Test func aCommandWithNoArgumentsIsStillTheCommand() async throws {
        let backend = MockBackend(agentType: .claudeCode)
        let conversation = AgentConversation(backend: backend, sessionID: "s")

        try await conversation.compact(
            model: ModelSelection(providerID: "opencode", modelID: "big-pickle"),
            reasoningEffort: "max")

        let sent = try #require(backend.recordedPrompts.last)
        #expect(sent.text == "/compact")
        #expect(sent.model?.modelID == "big-pickle")
        #expect(sent.reasoningEffort == "max")
    }

    /// A goal is a turn someone starts from a sheet rather than the box, and it runs on the same
    /// model the box would have used.
    @Test func goalTurnsCarryThePick() async throws {
        let backend = MockBackend(agentType: .claudeCode)
        let conversation = AgentConversation(backend: backend, sessionID: "s")

        try await conversation.setGoal(
            "the tests pass",
            model: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
            reasoningEffort: "high")
        try await conversation.clearGoal(
            model: ModelSelection(providerID: "anthropic", modelID: "claude-sonnet-5"),
            reasoningEffort: "high")

        #expect(backend.recordedPrompts.map(\.text) == ["/goal the tests pass", "/goal clear"])
        #expect(backend.recordedPrompts.allSatisfy { $0.model?.modelID == "claude-sonnet-5" })
        #expect(backend.recordedPrompts.allSatisfy { $0.reasoningEffort == "high" })
    }

    /// Nothing picked stays nothing sent: an unpicked run must not invent a model, or a server
    /// whose own default is the right answer would be overridden by a guess.
    @Test func anUnpickedRunCarriesNothing() async throws {
        let backend = MockBackend(agentType: .claudeCode)
        let conversation = AgentConversation(backend: backend, sessionID: "s")

        try await conversation.run(command)

        let sent = try #require(backend.recordedPrompts.last)
        #expect(sent.model == nil)
        #expect(sent.reasoningEffort == nil)
        #expect(sent.agent == nil)
    }
}
