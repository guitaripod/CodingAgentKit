import AgentTestSupport
import Foundation
import Testing

@testable import AgentCore

private let fastPolicy = ConnectionPolicy(
    reconnectBaseDelay: .milliseconds(5),
    reconnectMaxDelay: .milliseconds(20),
    reconnectJitter: 0
)

private let askInput = """
{"questions":[{"question":"Dark only?","header":"Mode","multiSelect":false,\
"options":[{"label":"Keep dark","description":"Forced dark everywhere."},\
{"label":"Adapt","description":"Follow the system."}]}]}
"""

private func askEvent(id: String = "toolu_1", status: ToolStatus = .running) -> BackendEvent {
    let call = ToolCall(
        id: id, name: "AskUserQuestion", status: status,
        input: try! JSONDecoder().decode(JSONValue.self, from: Data(askInput.utf8)))
    return .messageUpserted(
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: id, kind: .tool(call))],
            createdAt: Date(timeIntervalSince1970: 0)),
        replaceParts: true)
}

private func conversation(_ backend: MockBackend) -> AgentConversation {
    AgentConversation(backend: backend, sessionID: "s", policy: fastPolicy)
}

private func firstQuestion(_ conversation: AgentConversation) async -> QuestionRequest? {
    for await state in await conversation.states() where !state.pendingQuestions.isEmpty {
        return state.pendingQuestions.first
    }
    return nil
}

@Suite struct TranscriptQuestionTests {
    /// Claude's ask is a tool call that blocks on its own result, so nothing ever
    /// pushes a question event — the card exists only if the transcript is read.
    @Test func surfacesAnUnansweredAskFromTheTranscript() async throws {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [MockScriptStep(askEvent()), MockScriptStep(.status(.idle))],
            derivesQuestionsFromTranscript: true)
        let question = try #require(await firstQuestion(conversation(backend)))
        #expect(question.id == "toolu_1")
        #expect(question.questions.first?.question == "Dark only?")
        #expect(question.questions.first?.options.map(\.label) == ["Keep dark", "Adapt"])
    }

    @Test func leavesAnAnsweredAskAlone() async {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [
                MockScriptStep(askEvent(status: .completed)), MockScriptStep(.status(.idle)),
            ],
            derivesQuestionsFromTranscript: true)
        let conversation = conversation(backend)
        for await state in await conversation.states() where state.status == .idle {
            #expect(state.pendingQuestions.isEmpty)
            break
        }
    }

    /// The answer goes out as a message, so the tool call stays unanswered in the
    /// transcript forever. Without remembering what was settled, every refresh
    /// would re-raise a question the user already answered.
    @Test func answeredQuestionDoesNotComeBackOnRefresh() async throws {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [MockScriptStep(askEvent()), MockScriptStep(.status(.idle))],
            derivesQuestionsFromTranscript: true)
        let conversation = conversation(backend)
        let question = try #require(await firstQuestion(conversation))

        try await conversation.answer(question, answers: [["Keep dark"]])
        #expect(await conversation.state.pendingQuestions.isEmpty)

        try await conversation.refresh()
        #expect(await conversation.state.pendingQuestions.isEmpty)
    }

    @Test func dismissedQuestionDoesNotComeBackOnRefresh() async throws {
        let backend = MockBackend(
            agentType: .claudeCode,
            script: [MockScriptStep(askEvent()), MockScriptStep(.status(.idle))],
            derivesQuestionsFromTranscript: true)
        let conversation = conversation(backend)
        let question = try #require(await firstQuestion(conversation))

        try await conversation.reject(question)
        try await conversation.refresh()
        #expect(await conversation.state.pendingQuestions.isEmpty)
    }

    /// A backend that does not read questions out of transcripts must not start
    /// doing so because the transcript happens to contain an ask.
    @Test func staysOffForBackendsThatPushQuestions() async {
        let backend = MockBackend(
            agentType: .openCode,
            script: [MockScriptStep(askEvent()), MockScriptStep(.status(.idle))])
        let conversation = conversation(backend)
        for await state in await conversation.states() where state.status == .idle {
            #expect(state.pendingQuestions.isEmpty)
            break
        }
    }
}
