import Foundation

extension ToolCall {
    /// Whether this call is the agent putting a structured question to the user
    /// (Claude Code's `AskUserQuestion`). Such a call is an ordinary tool call
    /// whose *result* is the answer, so it stays running until someone answers —
    /// a client that renders it as a plain tool row shows a spinner forever
    /// instead of the form the agent is waiting on.
    public var asksUserQuestion: Bool {
        name.caseInsensitiveCompare("AskUserQuestion") == .orderedSame
    }

    public var isAwaitingAnswer: Bool {
        asksUserQuestion && (status == .running || status == .pending)
    }

    /// The answers already recorded, read back from the tool result the agent
    /// harness writes ("Your questions have been answered: "Q"="A"."), so a
    /// resolved ask still reads as the decision it captured.
    public var recordedAnswers: [AnsweredQuestion] {
        guard asksUserQuestion, let output, !output.isEmpty else { return [] }
        let range = NSRange(output.startIndex..., in: output)
        return AnsweredQuestion.pairPattern?.matches(in: output, range: range)
            .compactMap { match in
                guard let question = Range(match.range(at: 1), in: output),
                    let answer = Range(match.range(at: 2), in: output)
                else { return nil }
                return AnsweredQuestion(
                    question: String(output[question]), answer: String(output[answer]))
            } ?? []
    }
}

/// One question/answer pair recovered from an answered ask.
public struct AnsweredQuestion: Sendable, Hashable {
    public let question: String
    public let answer: String

    public init(question: String, answer: String) {
        self.question = question
        self.answer = answer
    }

    fileprivate static let pairPattern = try? NSRegularExpression(
        pattern: "\"([^\"]*)\"=\"([^\"]*)\"")
}

extension QuestionRequest {
    /// Reads an `AskUserQuestion` tool call into the backend-agnostic question
    /// model, so the same card renders it as renders opencode's question tool.
    /// Every question accepts a custom answer: the reply travels back as an
    /// ordinary message, which is free-form by nature.
    public init?(toolCall: ToolCall, sessionID: String) {
        guard toolCall.asksUserQuestion,
            case .array(let raw)? = toolCall.input?["questions"]
        else { return nil }
        let items = raw.compactMap(Item.init(askUserQuestion:))
        guard !items.isEmpty else { return nil }
        self.init(id: toolCall.id, sessionID: sessionID, questions: items)
    }
}

extension QuestionRequest.Item {
    fileprivate init?(askUserQuestion json: JSONValue) {
        guard let question = json["question"]?.stringValue,
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var options: [QuestionRequest.Option] = []
        if case .array(let raw)? = json["options"] {
            options = raw.compactMap { option in
                guard let label = option["label"]?.stringValue, !label.isEmpty else { return nil }
                return QuestionRequest.Option(
                    label: label, description: option["description"]?.stringValue ?? "")
            }
        }
        self.init(
            question: question,
            header: json["header"]?.stringValue ?? "",
            options: options,
            multiple: json["multiSelect"]?.boolValue ?? false,
            custom: true)
    }
}

extension QuestionRequest {
    /// The ask still waiting on the user in a transcript, for agents whose
    /// ask-the-user tool blocks on its own tool result.
    ///
    /// Only the newest ask counts, and only while the user has said nothing
    /// since. An answer delivered as a message never writes the tool result, so
    /// the call stays open in the transcript for good — going by status alone
    /// would re-raise a question the user settled hours ago, every time the
    /// conversation is reopened. Anything the user has said since is their
    /// answer, in their own words or ours.
    public static func awaitingAnswer(
        in messages: [ChatMessage], sessionID: String
    ) -> [QuestionRequest] {
        for message in messages.reversed() {
            if message.role == .user { return [] }
            guard message.role == .assistant else { continue }
            for part in message.parts.reversed() {
                guard case .tool(let call) = part.kind, call.asksUserQuestion else { continue }
                guard call.isAwaitingAnswer,
                    let request = QuestionRequest(toolCall: call, sessionID: sessionID)
                else { return [] }
                return [request]
            }
        }
        return []
    }

    /// The answer phrased as a message, for agents that have no side channel to
    /// resolve an ask: the reply is delivered as the next user turn, naming the
    /// question so the agent can match it even when several were asked at once.
    public func answerMessage(_ answers: [[String]]) -> String {
        zip(questions, answers)
            .filter { !$0.1.isEmpty }
            .map { item, picked in
                "Answering \"\(item.question)\": \(picked.joined(separator: ", "))"
            }
            .joined(separator: "\n")
    }
}
