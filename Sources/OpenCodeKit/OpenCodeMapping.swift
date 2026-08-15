import AgentCore
import Foundation

enum OpenCodeMapping {
    static func date(_ milliseconds: Double?) -> Date {
        Date(timeIntervalSince1970: (milliseconds ?? 0) / 1000)
    }

    static func role(_ raw: String) -> MessageRole {
        switch raw {
        case "user": return .user
        case "assistant": return .assistant
        default: return .system
        }
    }

    static func toolStatus(_ raw: String?) -> ToolStatus {
        ToolStatus(rawValue: raw ?? "") ?? .pending
    }

    static func errorMessage(_ value: JSONValue) -> String? {
        if let message = value["data"]?["message"]?.stringValue { return message }
        if let name = value["name"]?.stringValue { return name }
        if case .string(let string) = value { return string }
        return value.compactDescription
    }

    static func project(_ project: OCProject) -> AgentProject? {
        guard let worktree = project.worktree, !worktree.isEmpty else { return nil }
        return AgentProject(
            id: project.id, worktree: worktree,
            updatedAt: project.time?.updated.map { date($0) })
    }

    /// The session record says nothing about a turn being open — opencode keeps that in its own
    /// status routes — so liveness arrives beside the record rather than inside it. A caller with
    /// no status to hand leaves `isActive` nil, which is *unknown* and never *idle*: a listing
    /// that cannot see a turn must not report there is none.
    static func session(_ session: OCSession, status: OCSessionStatus? = nil) -> AgentSession {
        AgentSession(
            id: session.id,
            agentType: .openCode,
            title: session.title ?? session.id,
            parentID: session.parentID,
            directory: session.directory,
            createdAt: date(session.time?.created),
            updatedAt: date(session.time?.updated ?? session.time?.created),
            isActive: status.map(isRunning),
            model: session.model?.id,
            modelProviderID: session.model?.providerID,
            reasoningEffort: session.model?.variant
        )
    }

    /// opencode calls a turn it is running `busy` on the workspace route and `running` on the
    /// process-wide one; `retry` is a turn waiting on the provider between attempts, which is a
    /// turn in flight rather than a conversation that has settled.
    static func isRunning(_ status: OCSessionStatus) -> Bool {
        status.type == "busy" || status.type == "running" || status.type == "retry"
    }

    /// How recently a child was written to, for a server too old to answer either status route.
    /// The guess is only ever made about a subagent, whose whole life is one turn: a chat is never
    /// called live on a timestamp.
    static let subagentActivityWindow: TimeInterval = 45

    static func subagent(_ session: OCSession, running: Set<String>? = nil) -> SubagentSummary {
        let updatedAt = date(session.time?.updated ?? session.time?.created)
        let active =
            running.map { $0.contains(session.id) }
            ?? (updatedAt.timeIntervalSinceNow > -subagentActivityWindow)
        return SubagentSummary(
            id: session.id,
            title: session.title ?? SubagentSummary.untitled,
            updatedAt: updatedAt,
            isActive: active,
            isCompleted: !active)
    }

    static func shell(_ message: OCMessage) -> ChatMessage {
        let messageRole = role(message.role)
        let completed = message.time?.completed
        return ChatMessage(
            id: message.id,
            role: messageRole,
            agentType: .openCode,
            parts: [],
            createdAt: date(message.time?.created),
            completedAt: completed.map(date),
            isStreaming: messageRole == .assistant && completed == nil,
            error: message.error.flatMap(errorMessage),
            costUSD: message.cost,
            providerID: message.providerID,
            modelID: message.modelID,
            reasoningEffort: message.variant,
            totalTokens: totalTokens(message.tokens),
            finishReason: message.finish
        )
    }

    private static func totalTokens(_ tokens: OCTokens?) -> Int? {
        guard let tokens else { return nil }
        let input: Double = tokens.input ?? 0
        let output: Double = tokens.output ?? 0
        let reasoning: Double = tokens.reasoning ?? 0
        let cacheRead: Double = tokens.cache?.read ?? 0
        let cacheWrite: Double = tokens.cache?.write ?? 0
        let total = input + output + reasoning + cacheRead + cacheWrite
        return total > 0 ? Int(total) : nil
    }

    static func part(_ part: OCPart) -> MessagePart {
        let kind: MessagePart.Kind
        switch part.type {
        case "text":
            kind = .text(part.text ?? "")
        case "reasoning":
            kind = .reasoning(part.text ?? "")
        case "tool":
            kind = .tool(
                ToolCall(
                    id: part.callID ?? part.id,
                    name: part.tool ?? "tool",
                    status: toolStatus(part.state?.status),
                    input: part.state?.input,
                    output: part.state?.output ?? part.state?.error,
                    title: part.state?.title
                ))
        case "file":
            kind = .file(
                FileReference(
                    path: nil, mime: part.mime, url: part.url,
                    filename: Self.displayName(part.filename)))
        case "compaction":
            kind = .compaction(
                Compaction(trigger: part.auto.map { $0 ? .auto : .manual }, summary: nil))
        default:
            kind = .unknown(type: part.type)
        }
        return MessagePart(id: part.id, kind: kind)
    }

    /// opencode puts the full path in an assistant file part's filename; the
    /// bubble caption wants just the last component.
    static func displayName(_ filename: String?) -> String? {
        filename.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static func question(_ dto: OCQuestionRequestDTO) -> QuestionRequest? {
        guard !dto.questions.isEmpty else { return nil }
        return QuestionRequest(
            id: dto.id,
            sessionID: dto.sessionID,
            questions: dto.questions.map { item in
                QuestionRequest.Item(
                    question: item.question,
                    header: item.header ?? "",
                    options: (item.options ?? []).map {
                        QuestionRequest.Option(label: $0.label, description: $0.description ?? "")
                    },
                    multiple: item.multiple ?? false,
                    custom: item.custom ?? false)
            })
    }

    static func message(_ envelope: OCMessageEnvelope) -> ChatMessage {
        var message = shell(envelope.info)
        message.parts = envelope.parts.map(part)
        return message
    }

    /// The whole message list read as a transcript. opencode writes a compaction as pieces no
    /// transcript wants as-is: a marker part on an otherwise empty user message, then an assistant
    /// message whose text is the summary and whose `mode` says `compaction`. Read together the two
    /// are one seam — a system message carrying a single compaction part with the summary inside —
    /// and read separately they are noise: the marker is dropped, and the summary's prose lives
    /// behind the seam card rather than as an answer bubble.
    /// When the transcript itself says a compaction is still running, and since when.
    ///
    /// opencode writes the marker part the moment `summarize` begins and the summary only when it
    /// ends, so a marker with no compaction-mode assistant message after it *is* the running
    /// compaction — the one authority that outlives whichever process started it. Only the last
    /// marker can be the live one; an earlier unmatched marker belongs to an attempt that is over.
    ///
    /// A marker older than ``staleMarker`` is not reported. Summarizing takes minutes, not hours,
    /// and a failed one can leave its marker behind for good: without a clock on it, one dead
    /// marker would pin "Compacting…" over a conversation for the rest of its life.
    static func compactionInFlight(_ envelopes: [OCMessageEnvelope], now: Date = Date()) -> Date? {
        var startedAt: Date?
        for envelope in envelopes {
            if envelope.parts.contains(where: { $0.type == "compaction" }) {
                startedAt = envelope.info.time?.created.map(date) ?? now
                continue
            }
            if envelope.info.role == "assistant", envelope.info.mode == "compaction" {
                startedAt = nil
            }
        }
        guard let startedAt, now.timeIntervalSince(startedAt) < staleMarker else { return nil }
        return startedAt
    }

    /// How long an unanswered compaction marker is believed for.
    static let staleMarker: TimeInterval = 30 * 60

    static func transcript(_ envelopes: [OCMessageEnvelope]) -> [ChatMessage] {
        var pendingAuto: Bool?
        var result: [ChatMessage] = []
        for envelope in envelopes {
            let marker = envelope.parts.first { $0.type == "compaction" }
            if let marker {
                pendingAuto = marker.auto
                let rest = envelope.parts.filter { $0.type != "compaction" }
                if rest.isEmpty { continue }
                var message = shell(envelope.info)
                message.parts = rest.map(part)
                result.append(message)
                continue
            }
            if envelope.info.role == "assistant", envelope.info.mode == "compaction" {
                let prose = envelope.parts
                    .compactMap { $0.type == "text" ? $0.text : nil }
                    .joined(separator: "\n\n")
                var seam = shell(envelope.info)
                seam.role = .system
                seam.parts = [
                    MessagePart(
                        id: envelope.info.id + "/compaction",
                        kind: .compaction(
                            Compaction(
                                trigger: pendingAuto.map { $0 ? .auto : .manual } ?? .manual,
                                summary: prose.isEmpty ? nil : prose)))
                ]
                result.append(seam)
                pendingAuto = nil
                continue
            }
            result.append(message(envelope))
        }
        return result
    }
}
