import Foundation

/// A backend-agnostic reading of a tool call for presentation: what family of
/// action it is, the human line that names it, and which raw payloads are
/// worth rendering versus harness plumbing. Clients map this to visuals; the
/// extraction itself stays testable and shared across agents.
public struct ToolCallSummary: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case shell
        case fileRead
        case fileEdit
        case fileWrite
        case fileSearch
        case webSearch
        case webFetch
        case taskTracking
        case subagent
        case workflow
        case skill
        case other
    }

    public struct Link: Sendable, Hashable {
        public let title: String
        public let url: URL

        public init(title: String, url: URL) {
            self.title = title
            self.url = url
        }
    }

    public struct DiffStats: Sendable, Hashable {
        public let added: Int
        public let removed: Int

        public init(added: Int, removed: Int) {
            self.added = added
            self.removed = removed
        }
    }

    public let kind: Kind
    /// Primary human line: a shell command's description, a file's basename,
    /// a search query, a spawned agent's mission.
    public let title: String?
    /// Secondary line: a file's directory, a subagent type, skill arguments.
    public let detail: String?
    /// Compact measurement such as a read file's line count.
    public let metric: String?
    /// The exact shell command for monospaced display.
    public let command: String?
    public let filePath: String?
    public let links: [Link]
    public let diffStats: DiffStats?
    /// Output ready to render, with harness plumbing stripped; nil when the
    /// raw output carries nothing a reader needs (file dumps, success acks).
    public let displayOutput: String?
}

extension ToolCall {
    public var summary: ToolCallSummary {
        ToolCallSummaryBuilder.build(self)
    }
}

enum ToolCallSummaryBuilder {
    static func build(_ call: ToolCall) -> ToolCallSummary {
        let kind = classify(call.name)
        switch kind {
        case .shell: return shell(call, kind)
        case .fileRead: return fileRead(call, kind)
        case .fileEdit, .fileWrite: return fileChange(call, kind)
        case .fileSearch: return fileSearch(call, kind)
        case .webSearch: return webSearch(call, kind)
        case .webFetch: return webFetch(call, kind)
        case .taskTracking: return taskTracking(call, kind)
        case .subagent: return subagent(call, kind)
        case .workflow: return workflow(call, kind)
        case .skill: return skill(call, kind)
        case .other:
            return make(kind, displayOutput: strippedOutput(call))
        }
    }

    static func classify(_ name: String) -> ToolCallSummary.Kind {
        let lowered = name.lowercased()
        func contains(_ needles: String...) -> Bool {
            needles.contains { lowered.contains($0) }
        }
        if contains("todo") || contains("taskcreate", "taskupdate", "tasklist", "taskget") {
            return .taskTracking
        }
        if lowered == "task" || lowered == "agent" { return .subagent }
        if contains("workflow") { return .workflow }
        if lowered == "skill" { return .skill }
        if contains("websearch") { return .webSearch }
        if contains("webfetch", "fetch", "http") { return .webFetch }
        if contains("bash", "shell", "terminal", "exec") { return .shell }
        if contains("edit", "patch", "str_replace", "apply") { return .fileEdit }
        if contains("write", "create") { return .fileWrite }
        if contains("read", "cat", "view", "notebook") { return .fileRead }
        if contains("grep", "glob", "search", "find") || lowered == "ls" || contains("list") {
            return .fileSearch
        }
        return .other
    }

    private static func shell(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let command = field(call, "command")
        let title = field(call, "description") ?? command.map(firstLine)
        return make(
            kind, title: title, command: command, displayOutput: strippedOutput(call))
    }

    private static func fileRead(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let path = anyPath(call)
        var metric: String?
        if let output = call.output, !output.isEmpty {
            let lines = output.reduce(into: 1) { count, char in
                if char == "\n" { count += 1 }
            }
            metric = "\(lines) line\(lines == 1 ? "" : "s")"
        }
        return make(
            kind, title: path.map(basename), detail: path.map(directory), metric: metric,
            filePath: path, displayOutput: path == nil ? strippedOutput(call) : nil)
    }

    private static func fileChange(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let path = anyPath(call)
        var added = 0
        var removed = 0
        if let old = field(call, "old_string") { removed = lineCount(old) }
        if let new = field(call, "new_string") {
            added = lineCount(new)
        } else if let content = field(call, "content") {
            added = lineCount(content)
        }
        let stats = (added > 0 || removed > 0)
            ? ToolCallSummary.DiffStats(added: added, removed: removed) : nil
        return make(
            kind, title: path.map(basename), detail: path.map(directory),
            filePath: path, diffStats: stats,
            displayOutput: (path == nil && stats == nil) ? strippedOutput(call) : nil)
    }

    private static func fileSearch(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let pattern = field(call, "pattern") ?? field(call, "query")
        let path = field(call, "path")
        return make(
            kind, title: pattern ?? path, detail: pattern != nil ? path : nil,
            filePath: path, displayOutput: strippedOutput(call))
    }

    private static func webSearch(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let (links, prose) = parseSearchOutput(call.output)
        return make(
            kind, title: field(call, "query"), links: links, displayOutput: prose)
    }

    private static func webFetch(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let raw = field(call, "url")
        let host = raw.flatMap(URL.init(string:))?.host
        return make(
            kind, title: host ?? raw, detail: host != nil ? raw : nil,
            displayOutput: strippedOutput(call))
    }

    private static func taskTracking(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        var title = field(call, "subject")
        if title == nil, let id = field(call, "taskId") { title = "Task #\(id)" }
        let status = field(call, "status")
        return make(
            kind, title: title,
            detail: status.map { $0.replacingOccurrences(of: "_", with: " ") })
    }

    private static func subagent(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let title = field(call, "description")
            ?? field(call, "prompt").map { firstLine(String($0.prefix(120))) }
        let type = field(call, "subagent_type")
        return make(
            kind, title: title,
            detail: (type?.isEmpty == false && type != "general-purpose") ? type : nil,
            displayOutput: strippedOutput(call))
    }

    private static func workflow(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        let name = field(call, "name") ?? field(call, "script").flatMap(scriptName)
        return make(kind, title: name)
    }

    private static func skill(_ call: ToolCall, _ kind: ToolCallSummary.Kind) -> ToolCallSummary {
        make(
            kind, title: field(call, "skill"),
            detail: field(call, "args").flatMap { $0.isEmpty ? nil : String($0.prefix(60)) })
    }

    private static func make(
        _ kind: ToolCallSummary.Kind, title: String? = nil, detail: String? = nil,
        metric: String? = nil, command: String? = nil, filePath: String? = nil,
        links: [ToolCallSummary.Link] = [], diffStats: ToolCallSummary.DiffStats? = nil,
        displayOutput: String? = nil
    ) -> ToolCallSummary {
        ToolCallSummary(
            kind: kind, title: title, detail: detail, metric: metric, command: command,
            filePath: filePath, links: links, diffStats: diffStats,
            displayOutput: displayOutput?.isEmpty == false ? displayOutput : nil)
    }

    private static func field(_ call: ToolCall, _ key: String) -> String? {
        call.input?[key]?.stringValue
    }

    private static func anyPath(_ call: ToolCall) -> String? {
        field(call, "file_path") ?? field(call, "path") ?? field(call, "notebook_path")
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func directory(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
    }

    private static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.reduce(into: 1) { count, char in
            if char == "\n" { count += 1 }
        }
    }

    private static func strippedOutput(_ call: ToolCall) -> String? {
        guard let output = call.output, !output.isEmpty else { return nil }
        let stripped = AgentMarkup.strip(output)
        return stripped.isEmpty ? nil : stripped
    }

    /// Splits a web-search tool output into its embedded `Links: [...]` array
    /// and the remaining synthesized prose, dropping the echo-the-query header.
    private static func parseSearchOutput(
        _ output: String?
    ) -> (links: [ToolCallSummary.Link], prose: String?) {
        guard let output, !output.isEmpty else { return ([], nil) }
        var links: [ToolCallSummary.Link] = []
        var proseLines: [String] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Web search results for query:") { continue }
            if trimmed.hasPrefix("Links:"), links.isEmpty {
                links = parseLinkArray(trimmed)
                if !links.isEmpty { continue }
            }
            proseLines.append(line)
        }
        let prose = proseLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (links, prose.isEmpty ? nil : AgentMarkup.strip(prose))
    }

    private static func parseLinkArray(_ line: String) -> [ToolCallSummary.Link] {
        guard let start = line.firstIndex(of: "["),
            let end = line.lastIndex(of: "]"), start < end,
            let data = String(line[start...end]).data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { entry in
            guard let raw = entry["url"] as? String, let url = URL(string: raw) else { return nil }
            let title = (entry["title"] as? String)?
                .trimmingCharacters(in: .whitespaces)
            return ToolCallSummary.Link(
                title: title?.isEmpty == false ? title! : (url.host ?? raw), url: url)
        }
    }

    private static let scriptNameRegex = try? NSRegularExpression(
        pattern: "name:\\s*['\"]([^'\"]+)['\"]")

    private static func scriptName(_ script: String) -> String? {
        let head = String(script.prefix(500))
        guard let match = scriptNameRegex?.firstMatch(
                in: head, range: NSRange(head.startIndex..., in: head)),
            let range = Range(match.range(at: 1), in: head)
        else { return nil }
        return String(head[range])
    }
}
