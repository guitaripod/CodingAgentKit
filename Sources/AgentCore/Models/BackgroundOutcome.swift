import Foundation

/// What a tool call that handed its work to the background was told when that work reported back.
///
/// A tool that starts something and answers at once — a workflow run, a background shell command —
/// has an outcome its own `output` can never carry: the call was over in milliseconds and the work
/// runs for minutes. The harness reports the end separately, naming the call it belongs to, and
/// this is that report seated back on the call. Without it a client watching such a call can only
/// ever see that the launch succeeded, which is a record of something that started and nothing
/// that stopped — and anything reading it as progress keeps moving for good.
public struct BackgroundOutcome: Sendable, Hashable, Codable {
    /// How the work ended. Every case is terminal: a report exists only because it stopped.
    public enum Status: String, Sendable, Hashable, Codable {
        case completed
        case failed
        /// Killed rather than finished — a timeout, a teardown, someone pressing stop. The work is
        /// over and there is no answer, which is a different fact from a failure.
        case stopped
    }

    /// The harness's own id for the work, which is what a launch banner names it by.
    public let taskID: String?
    public let status: Status
    /// The single line the harness wrote about the end, for a reader who wants no more than that.
    public let summary: String?
    /// What the work returned, already unwrapped from the JSON the harness writes it as.
    public let result: String?
    /// When the report landed, which is the only honest end stamp for work nothing was watching.
    public let reportedAt: Date?

    public init(
        taskID: String? = nil, status: Status, summary: String? = nil, result: String? = nil,
        reportedAt: Date? = nil
    ) {
        self.taskID = taskID
        self.status = status
        self.summary = summary
        self.result = result
        self.reportedAt = reportedAt
    }

    public var isSuccess: Bool { status == .completed }

    /// The best thing to show a reader who came for the answer: what the work returned, or failing
    /// that the line the harness wrote about it. Never both, and never an empty string.
    public var answer: String? {
        for candidate in [result, summary] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}
