import AgentCore
import Testing

@Suite struct AgentTextTests {
    @Test func aPromptOfOnlyASlashCommandStillGetsAName() {
        #expect(AgentSession.provisionalTitle(fromPrompt: "/clear") == "Agent session")
        #expect(AgentSession.provisionalTitle(fromPrompt: "   ") == "Agent session")
    }
}
