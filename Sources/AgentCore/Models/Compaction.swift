import Foundation

/// A point where the agent replaced the conversation so far with a summary of it. Everything above
/// a compaction is still readable in the transcript but is no longer in the model's context — only
/// ``summary`` and the handful of messages named by ``preservedMessageCount`` survived.
public struct Compaction: Sendable, Hashable, Codable {
    public enum Trigger: String, Sendable, Hashable, Codable {
        /// The user asked for it (`/compact`).
        case manual
        /// The context window filled and the agent compacted on its own.
        case auto
    }

    /// Who asked for it, when the agent recorded that at all.
    public var trigger: Trigger?
    /// Context size immediately before the compaction, in tokens.
    public var tokensBefore: Int?
    /// Context size the summary reduced it to.
    public var tokensAfter: Int?
    public var duration: TimeInterval?
    /// Recent messages carried across verbatim alongside the summary.
    public var preservedMessageCount: Int?
    /// The summary the agent wrote and now carries in place of the dropped transcript.
    public var summary: String?

    public init(
        trigger: Trigger? = nil,
        tokensBefore: Int? = nil,
        tokensAfter: Int? = nil,
        duration: TimeInterval? = nil,
        preservedMessageCount: Int? = nil,
        summary: String? = nil
    ) {
        self.trigger = trigger
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.duration = duration
        self.preservedMessageCount = preservedMessageCount
        self.summary = summary
    }

    /// Tokens this compaction handed back to the context window.
    public var tokensFreed: Int? {
        guard let tokensBefore, let tokensAfter, tokensBefore > tokensAfter else { return nil }
        return tokensBefore - tokensAfter
    }

    /// How much of the context the compaction reclaimed, `0...1`.
    public var reduction: Double? {
        guard let tokensBefore, tokensBefore > 0, let freed = tokensFreed else { return nil }
        return Double(freed) / Double(tokensBefore)
    }
}

/// A compaction currently underway. Compaction re-reads the whole conversation and can take
/// minutes, so a client has to be able to say so rather than render an ordinary silent turn.
public struct CompactionActivity: Sendable, Hashable, Codable {
    public var startedAt: Date
    /// Set when the agent refused or failed to compact — the attempt is over and this explains why.
    public var failure: String?

    public init(startedAt: Date, failure: String? = nil) {
        self.startedAt = startedAt
        self.failure = failure
    }

    public var isRunning: Bool { failure == nil }
}
