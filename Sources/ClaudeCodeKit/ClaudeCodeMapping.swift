import AgentCore
import Foundation

enum ClaudeCodeMapping {
    static let contentPartID = "content"

    static func date(_ raw: String?) -> Date {
        guard let raw else { return Date() }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        return Date()
    }

    static func role(_ raw: String) -> MessageRole {
        switch raw {
        case "agent": return .assistant
        case "user": return .user
        default: return .system
        }
    }

    static func status(_ raw: String) -> BackendStatus {
        switch raw {
        case "running": return .running
        case "stable": return .stable
        case "idle": return .idle
        default: return .unknown
        }
    }

    static func chatMessage(id: Int, content: String, role rawRole: String, time: String?)
        -> ChatMessage
    {
        let messageRole = role(rawRole)
        return ChatMessage(
            id: String(id),
            role: messageRole,
            agentType: .claudeCode,
            parts: [MessagePart(id: contentPartID, kind: .text(clean(content, role: messageRole)))],
            createdAt: date(time),
            completedAt: nil,
            isStreaming: false,
            error: nil
        )
    }

    private static let spinnerGlyphs: Set<Character> = [
        "✻", "✽", "✢", "✳", "✶", "✷", "✴", "❋", "✦", "✧", "⋆", "∗", "✱", "·",
    ]

    /// Strips the interactive-terminal chrome agentapi scrapes from the Claude TUI (banner,
    /// status bar, MCP/usage callouts, slash-command echoes, and the ephemeral thinking spinner),
    /// leaving just the conversation text so a chat row's height stays stable.
    static func clean(_ raw: String, role: MessageRole) -> String {
        if role == .user {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("/") ? "" : trimmed
        }
        var kept: [String] = []
        var skippingControlResult = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                skippingControlResult = false
                kept.append("")
            } else if isControlResult(trimmed) {
                skippingControlResult = true
            } else if isChrome(trimmed) {
                continue
            } else if skippingControlResult && text.hasPrefix(" ") {
                continue
            } else {
                skippingControlResult = false
                kept.append(stripMarker(text).trimmingTrailingWhitespace())
            }
        }
        return collapseBlankRuns(kept)
    }

    private static func isControlResult(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("⎿")
            && (trimmed.contains("saved as your default") || trimmed.contains("Set model")
                || trimmed.contains("Set effort"))
    }

    private static func isChrome(_ trimmed: String) -> Bool {
        if trimmed.unicodeScalars.contains(where: { (0x2580...0x259F).contains($0.value) }) {
            return true
        }
        if let first = trimmed.first, spinnerGlyphs.contains(first) { return true }
        if trimmed.hasPrefix("⚠") || trimmed.hasPrefix("❯") { return true }
        for needle in [
            "· /effort", "/remote-control", "for shortcuts", "to interrupt", "weekly limit",
            "Learn more (https",
        ] where trimmed.contains(needle) {
            return true
        }
        return false
    }

    private static func stripMarker(_ line: String) -> String {
        var result = line.drop(while: { $0 == " " })
        for marker in ["⏺ ", "⏺"] where result.hasPrefix(marker) {
            result = result.dropFirst(marker.count)
            break
        }
        return String(result)
    }

    static func collapseBlankRuns(_ lines: [String]) -> String {
        var out: [String] = []
        for line in lines {
            if line.isEmpty && (out.last?.isEmpty ?? true) { continue }
            out.append(line)
        }
        while out.first?.isEmpty == true { out.removeFirst() }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func message(_ message: AAMessage) -> ChatMessage {
        chatMessage(
            id: message.id, content: message.content, role: message.role, time: message.time)
    }

    static func update(_ update: AAMessageUpdate) -> ChatMessage {
        chatMessage(id: update.id, content: update.message, role: update.role, time: update.time)
    }
}

extension String {
    fileprivate func trimmingTrailingWhitespace() -> String {
        var view = self[...]
        while let last = view.last, last == " " || last == "\t" {
            view = view.dropLast()
        }
        return String(view)
    }
}

public struct ClaudeAgentStatus: Sendable, Hashable {
    public let agentType: String?
    public let status: BackendStatus
    public let transport: String?

    public init(agentType: String?, status: BackendStatus, transport: String?) {
        self.agentType = agentType
        self.status = status
        self.transport = transport
    }
}
