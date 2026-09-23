import Foundation

/// A line the server wrote into a conversation for the person reading it rather than for the
/// model: the model or the agent changing hands, a turn picked back up after the server
/// restarted, work the agent left running coming back, instructions loaded partway through.
///
/// It is a fact about the conversation rather than something anybody said, so a client draws it
/// as a quiet line between the turns: never as a message, and never with the model-facing text
/// the server records beside it, which is written for the model and runs to pages.
public struct TranscriptNote: Sendable, Hashable, Codable {
    /// How work the agent had set running ended when it reported back.
    public enum Outcome: String, Sendable, Hashable, Codable {
        case completed
        case cancelled
        case failed
    }

    /// Which kind of work reported back.
    public enum Work: String, Sendable, Hashable, Codable {
        case command
        case agent
    }

    public enum Subject: Sendable, Hashable, Codable {
        /// The model answering from here on, with the effort it runs at, and the one that answered
        /// before it when the server knew.
        case model(ModelSelection, effort: String?, previous: ModelSelection?)
        /// The agent answering from here on, and the one before it when the server knew.
        case agent(String, previous: String?)
        /// The server restarted while a turn was running and picked it back up on its own.
        case resumedAfterRestart
        /// Work the agent started in the background finished, was cancelled or failed.
        case workFinished(String, work: Work, outcome: Outcome)
        /// The server loaded or changed the instructions the agent works under, in its own words.
        case instructions(String)
        /// The conversation moved to another directory.
        case moved(String)
        /// The agent took up a skill.
        case skill(String)
        /// Anything else the server described for display, in its own words.
        case remark(String)

        /// Whether this note is a model or an agent being chosen, which before anybody has
        /// written in the conversation is how it was set up rather than a change.
        public var isSelection: Bool {
            switch self {
            case .model, .agent: return true
            default: return false
            }
        }
    }

    public var subject: Subject

    public init(_ subject: Subject) {
        self.subject = subject
    }
}
