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

        /// What a turn had already done, read from the parts of the messages it wrote: every tool
        /// call counted, the files and commands they name, and the answer as far as it got. A
        /// turn a server writes one message per step is read across all of them.
        public init(reading turn: [ChatMessage]) {
            var toolCount = 0
            var lastTool: String?
            var files: [String] = []
            var commands: [String] = []
            var answer = ""
            for message in turn where message.role == .assistant {
                for part in message.parts {
                    switch part.kind {
                    case .text(let value):
                        answer += value
                    case .tool(let call):
                        toolCount += 1
                        let summary = ToolCallSummaryBuilder.build(call)
                        lastTool = summary.title ?? call.name
                        if let path = summary.filePath, !files.contains(path) { files.append(path) }
                        if let command = summary.command, !commands.contains(command) {
                            commands.append(command)
                        }
                    default:
                        continue
                    }
                }
            }
            let partial = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            self.init(
                toolCount: toolCount, lastTool: lastTool, filesTouched: files, commands: commands,
                partialAnswer: partial.isEmpty ? nil : partial)
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
    /// Whether the server holds the session's unattended work until somebody decides, as a bridge
    /// does that will not carry a conversation on by itself while a cut-off turn is undecided. A server
    /// with no such hold leaves the price of waiting unsaid, because there is none to pay.
    public let holdsUnattendedWork: Bool

    public init(
        turnID: String, prompt: String, startedAt: Date, detectedAt: Date,
        progress: Progress = Progress(), queued: [String] = [], resumedAt: Date? = nil,
        holdsUnattendedWork: Bool = true
    ) {
        self.turnID = turnID
        self.prompt = prompt
        self.startedAt = startedAt
        self.detectedAt = detectedAt
        self.progress = progress
        self.queued = queued
        self.resumedAt = resumedAt
        self.holdsUnattendedWork = holdsUnattendedWork
    }

    public var isResumed: Bool { resumedAt != nil }

    /// How long the turn had been running when the machine stopped.
    public var ranFor: TimeInterval { max(0, detectedAt.timeIntervalSince(startedAt)) }

    /// Whether anything at all was recorded before the turn was cut off. Nothing recorded is worth
    /// saying out loud: it means restarting the turn costs nothing and risks nothing.
    public var didAnything: Bool { !progress.isEmpty }
}
