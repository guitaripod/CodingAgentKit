import Foundation
import Testing

@testable import AgentCore

private func input(_ json: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
}

private let singleQuestion = """
{"questions":[{"question":"How do you want to get Odyssey installed?","header":"Path",\
"multiSelect":false,"options":[\
{"label":"Grab a different release","description":"A portable copy, no installer at all."},\
{"label":"Windows VM to extract once","description":"Headless qemu guest, 2-3 hours."}]}]}
"""

private let twoQuestions = """
{"questions":[\
{"question":"Dark only?","header":"Mode","multiSelect":false,\
"options":[{"label":"Keep dark","description":""},{"label":"Adapt","description":""}]},\
{"question":"Which clients?","header":"Scope","multiSelect":true,\
"options":[{"label":"Mac"},{"label":"iOS"}]}]}
"""

private func ask(
    _ json: String, id: String = "toolu_1", status: ToolStatus = .running, output: String? = nil
) -> ToolCall {
    ToolCall(
        id: id, name: "AskUserQuestion", status: status, input: input(json), output: output)
}

private func user(_ text: String) -> ChatMessage {
    ChatMessage(
        id: "u", role: .user, agentType: .claudeCode,
        parts: [MessagePart(id: "t", kind: .text(text))],
        createdAt: Date(timeIntervalSince1970: 1))
}

private func assistant(_ calls: [ToolCall], id: String = "m1") -> ChatMessage {
    ChatMessage(
        id: id, role: .assistant, agentType: .claudeCode,
        parts: calls.map { MessagePart(id: $0.id, kind: .tool($0)) },
        createdAt: Date(timeIntervalSince1970: 0))
}

@Suite struct UserQuestionTests {
    @Test func readsQuestionOptionsAndDescriptions() throws {
        let request = try #require(
            QuestionRequest(toolCall: ask(singleQuestion), sessionID: "s"))
        #expect(request.id == "toolu_1")
        #expect(request.sessionID == "s")
        #expect(request.questions.count == 1)
        let item = try #require(request.questions.first)
        #expect(item.question == "How do you want to get Odyssey installed?")
        #expect(item.header == "Path")
        #expect(item.multiple == false)
        #expect(item.options.map(\.label) == ["Grab a different release", "Windows VM to extract once"])
        #expect(item.options.first?.description == "A portable copy, no installer at all.")
    }

    /// The answer travels back as an ordinary message, so free text is always
    /// available — the card must offer it however the tool was called.
    @Test func alwaysAllowsACustomAnswer() throws {
        let request = try #require(QuestionRequest(toolCall: ask(singleQuestion), sessionID: "s"))
        #expect(request.questions.filter(\.custom).count == request.questions.count)
    }

    @Test func readsSeveralQuestionsAndMultiSelect() throws {
        let request = try #require(QuestionRequest(toolCall: ask(twoQuestions), sessionID: "s"))
        #expect(request.questions.map(\.header) == ["Mode", "Scope"])
        #expect(request.questions.map(\.multiple) == [false, true])
        #expect(request.questions.last?.options.map(\.label) == ["Mac", "iOS"])
        #expect(request.questions.last?.options.first?.description == "")
    }

    @Test func ignoresOtherToolsAndEmptyPayloads() {
        let other = ToolCall(id: "t", name: "Bash", status: .running, input: input(singleQuestion))
        #expect(QuestionRequest(toolCall: other, sessionID: "s") == nil)
        #expect(QuestionRequest(toolCall: ask("{\"questions\":[]}"), sessionID: "s") == nil)
        #expect(QuestionRequest(toolCall: ask("{}"), sessionID: "s") == nil)
        #expect(
            QuestionRequest(toolCall: ask("{\"questions\":[{\"header\":\"H\"}]}"), sessionID: "s")
                == nil)
    }

    @Test func readsRecordedAnswersBackFromTheResult() {
        let answered = ask(
            twoQuestions, status: .completed,
            output: """
                Your questions have been answered: "Dark only?"="Keep dark", \
                "Which clients?"="Mac". You can now continue with these answers in mind.
                """)
        #expect(
            answered.recordedAnswers == [
                AnsweredQuestion(question: "Dark only?", answer: "Keep dark"),
                AnsweredQuestion(question: "Which clients?", answer: "Mac"),
            ])
        #expect(ask(twoQuestions).recordedAnswers.isEmpty)
    }

    @Test func phrasesTheAnswerAsAMessage() throws {
        let request = try #require(QuestionRequest(toolCall: ask(twoQuestions), sessionID: "s"))
        #expect(
            request.answerMessage([["Keep dark"], ["Mac", "iOS"]]) == """
                Answering "Dark only?": Keep dark
                Answering "Which clients?": Mac, iOS
                """)
        #expect(request.answerMessage([[], ["Mac"]]) == "Answering \"Which clients?\": Mac")
        #expect(request.answerMessage([]).isEmpty)
    }

    @Test func findsTheNewestUnansweredAskInATranscript() throws {
        let messages = [
            assistant([ask(singleQuestion, id: "old", status: .completed, output: "answered")]),
            user("go on"),
            assistant([ask(twoQuestions, id: "new")], id: "m2"),
        ]
        let found = QuestionRequest.awaitingAnswer(in: messages, sessionID: "s")
        #expect(found.map(\.id) == ["new"])
    }

    /// The answer goes back as a message and never as a tool result, so the call
    /// stays open forever — what settles it is the user having spoken since.
    @Test func stopsAskingOnceTheUserHasRepliedToIt() {
        let messages = [
            assistant([ask(singleQuestion, id: "asked")]),
            user("Answering \"How do you want to get Odyssey installed?\": Windows VM"),
        ]
        #expect(QuestionRequest.awaitingAnswer(in: messages, sessionID: "s").isEmpty)

        let stillOpen = [
            assistant([ask(singleQuestion, id: "asked")]),
            assistant([], id: "m2"),
        ]
        #expect(QuestionRequest.awaitingAnswer(in: stillOpen, sessionID: "s").map(\.id) == ["asked"])
    }

    /// An ask the agent already resolved means nothing is waiting — and it hides
    /// any older ask the conversation has moved past.
    @Test func reportsNothingOnceTheNewestAskIsAnswered() {
        let messages = [
            assistant([ask(twoQuestions, id: "old")]),
            assistant([ask(singleQuestion, id: "new", status: .completed, output: "done")], id: "m2"),
        ]
        #expect(QuestionRequest.awaitingAnswer(in: messages, sessionID: "s").isEmpty)
        #expect(QuestionRequest.awaitingAnswer(in: [], sessionID: "s").isEmpty)
    }

    @Test func summarisesAnAskAsItsQuestionAndChosenAnswer() {
        let pending = ask(singleQuestion).summary
        #expect(pending.kind == .question)
        #expect(pending.title == "How do you want to get Odyssey installed?")
        #expect(pending.detail == nil)

        let answered = ask(
            singleQuestion, status: .completed,
            output: """
                Your questions have been answered: \
                "How do you want to get Odyssey installed?"="Grab a different release".
                """
        ).summary
        #expect(answered.detail == "Grab a different release")
        #expect(answered.displayOutput == nil)

        let multi = ask(twoQuestions).summary
        #expect(multi.title == "Dark only?  +1 more")
    }
}
