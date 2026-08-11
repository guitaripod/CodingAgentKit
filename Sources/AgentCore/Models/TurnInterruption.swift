import Foundation

/// A turn that was cut off by the machine rather than by the model.
///
/// A backend process that dies mid-turn leaves a conversation that looks finished: the prompt is
/// there, no answer follows, and nothing anywhere says an answer was ever coming. That is the one
/// failure a client must never render as silence — the agent may have been half way through
/// editing files when the power went — so a server that can tell the difference reports it as a
/// state with a name, an account of how far the work actually got, and something to do about it.
public struct TurnInterruption: Sendable, Hashable, Codable {
    /// What the turn had already done before it was cut off, read from the agent's own transcript
    /// rather than from anything it said about itself.
    public struct Progress: Sendable, Hashable, Codable {
        public let toolCount: Int
        public let lastTool: String?
        public let filesTouched: [String]
        public let commands: [String]
        /// How far the answer had got, when it had started one.
        public let partialAnswer: String?

        public init(
            toolCount: Int = 0, lastTool: String? = nil, filesTouched: [String] = [],
            commands: [String] = [], partialAnswer: String? = nil
        ) {
            self.toolCount = toolCount
            self.lastTool = lastTool
            self.filesTouched = filesTouched
            self.commands = commands
            self.partialAnswer = partialAnswer
        }

        public var isEmpty: Bool {
            toolCount == 0 && filesTouched.isEmpty && commands.isEmpty && partialAnswer == nil
        }
    }

    public let turnID: String
    /// The prompt the turn was answering, as the person wrote it.
    public let prompt: String
    public let startedAt: Date
    /// When the interruption was noticed, which is when the server came back — not when it happened.
    public let detectedAt: Date
    public let progress: Progress
    /// Prompts that were queued behind the interrupted turn and never ran.
    public let queued: [String]
    /// Set once the work has been picked back up, so the offer stops standing without the record
    /// being lost while the resumed turn is still running.
    public let resumedAt: Date?

    public init(
        turnID: String, prompt: String, startedAt: Date, detectedAt: Date,
        progress: Progress = Progress(), queued: [String] = [], resumedAt: Date? = nil
    ) {
        self.turnID = turnID
        self.prompt = prompt
        self.startedAt = startedAt
        self.detectedAt = detectedAt
        self.progress = progress
        self.queued = queued
        self.resumedAt = resumedAt
    }

    public var isResumed: Bool { resumedAt != nil }

    /// How long the turn had been running when the machine stopped.
    public var ranFor: TimeInterval { max(0, detectedAt.timeIntervalSince(startedAt)) }

    /// Whether anything at all was recorded before the turn was cut off. Nothing recorded is worth
    /// saying out loud: it means restarting the turn costs nothing and risks nothing.
    public var didAnything: Bool { !progress.isEmpty }
}
