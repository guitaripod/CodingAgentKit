import Foundation

extension ToolCall {
    /// Whether this call spawned a subagent whose transcript can be browsed —
    /// its `id` matches the spawned agent's `SubagentSummary.toolUseID`.
    public var spawnsSubagent: Bool {
        let lowered = name.lowercased()
        return lowered == "task" || lowered == "agent"
    }

    /// `output` with harness-internal markup removed.
    public var sanitizedOutput: String? {
        output.map(AgentMarkup.strip)
    }
}

/// Harness transcripts embed internal markup (system reminders, task
/// notifications) that means nothing to a human reader; strip it before
/// rendering agent or tool text.
public enum AgentMarkup {
    private static let blockRegex = try? NSRegularExpression(
        pattern: "<(system-reminder|task-notification)>[\\s\\S]*?</\\1>")
    private static let blankRunRegex = try? NSRegularExpression(pattern: "\\n{3,}")

    public static func strip(_ text: String) -> String {
        guard text.contains("<system-reminder>") || text.contains("<task-notification>"),
            let blockRegex, let blankRunRegex
        else { return text }
        var cleaned = blockRegex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        cleaned = blankRunRegex.stringByReplacingMatches(
            in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "\n\n")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AgentSession {
    /// Backend-generated placeholder titles that a client should replace with
    /// its own fallback naming.
    public static func isPlaceholderTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("New session")
    }

    public var hasPlaceholderTitle: Bool { Self.isPlaceholderTitle(title) }
}
