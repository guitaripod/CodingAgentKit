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
            || trimmed == "New chat" || trimmed.hasPrefix("/")
    }

    public var hasPlaceholderTitle: Bool { Self.isPlaceholderTitle(title) }

    /// A readable provisional title from a raw prompt, for surfaces that need
    /// a name before the server auto-titles (a Live Activity started at send
    /// time): first real line, markup stripped, cut at a word boundary.
    public static func provisionalTitle(fromPrompt text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: "<[^>]{1,80}>", with: " ", options: .regularExpression)
        let line = cleaned
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("/") }
        guard var title = line else { return "Agent session" }
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if title.count > 48 {
            let prefix = String(title.prefix(48))
            if let space = prefix.lastIndex(of: " "),
                prefix.distance(from: prefix.startIndex, to: space) > 24
            {
                title = String(prefix[..<space]) + "…"
            } else {
                title = prefix + "…"
            }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;–—-"))
        guard !title.isEmpty else { return "Agent session" }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}
