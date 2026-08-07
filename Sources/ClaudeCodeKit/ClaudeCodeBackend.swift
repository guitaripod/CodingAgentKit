import AgentCore
import Foundation

public struct ClaudeCodeBackend: CodingAgentBackend {
    public let agentType: AgentType = .claudeCode
    public let capabilities = BackendCapabilities(
        supportsFileBrowsing: true,
        supportsDiffs: false,
        supportsPermissions: false,
        supportsMultipleSessions: true,
        supportsModelSelection: true,
        supportsAttachments: true,
        supportsReasoningEffort: true,
        supportsClearing: true,
        supportsForking: true,
        supportsAbort: true,
        supportsSessionUsage: true,
        supportsQuestions: true,
        answersQuestionsByMessage: true,
        supportsRenaming: true,
        supportsSubagents: true,
        supportsCommands: true,
        supportsGoals: true,
        supportsCompaction: true,
        reportsMessageCompletion: false,
        supportsTranscriptSearch: true
    )

    private static let vision = ModelCapabilities(
        attachment: true, imageInput: true, pdfInput: true)

    public static let models: [ModelInfo] = [
        ModelInfo(id: "fable", name: "Fable", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "opus[1m]", name: "Opus 1M", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic", capabilities: vision),
    ]

    /// `ultracode` is a mode more than a level — the server maps it to xhigh
    /// effort plus standing multi-agent workflow orchestration for the session.
    public var reasoningEffortOptions: [String] { ["low", "medium", "high", "xhigh", "max", "ultracode"] }

    private let builder: RequestBuilder
    private let http: HTTPClient
    private let stream: BridgeStream

    public init(config: ServerConfig) {
        let builder = RequestBuilder(config: config)
        let http = HTTPClient(policy: config.policy, logger: AgentLog.logger("claude-bridge"))
        self.builder = builder
        self.http = http
        self.stream = BridgeStreamRegistry.stream(config: config, builder: builder, http: http)
    }

    /// `/status` doubles as the liveness check: it costs the same round trip as `/health` and
    /// carries the bridge's version, which is what a client shows and compares against a release.
    public func health() async throws -> ServerHealth {
        guard let data = try? await http.send(builder.request(.get, "/status")),
            let status = try? BridgeCoding.decoder.decode(BRStatus.self, from: data)
        else {
            _ = try await http.send(builder.request(.get, "/health"))
            return ServerHealth(healthy: true, version: nil)
        }
        return ServerHealth(healthy: true, version: status.version)
    }

    public func listSessions() async throws -> [AgentSession] {
        let data = try await http.send(builder.request(.get, "/sessions"))
        return try BridgeCoding.decoder.decode([BRLenient<BRSummary>].self, from: data)
            .compactMap(\.value).map(\.session)
    }

    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        let body = try BridgeCoding.encoder.encode(
            BRCreate(title: title, directory: directory, model: nil, effort: nil))
        let data = try await http.send(builder.request(.post, "/sessions", body: body))
        return try BridgeCoding.decoder.decode(BRSession.self, from: data).session
    }

    public func deleteSession(_ sessionID: String) async throws {
        _ = try await http.send(builder.request(.delete, "/sessions/\(sessionID)"))
    }

    public func abort(sessionID: String) async throws {
        _ = try await http.send(builder.request(.post, "/sessions/\(sessionID)/abort"))
    }

    public func subagents(for sessionID: String) async throws -> [SubagentSummary] {
        let data = try await http.send(builder.request(.get, "/sessions/\(sessionID)/agents"))
        return try BridgeCoding.decoder.decode([BRSubagent].self, from: data).map(\.summary)
    }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        let data = try await http.send(
            builder.request(.get, "/sessions/\(sessionID)/agents/\(agentID)"))
        return try BridgeCoding.decoder.decode(BRSubagentTranscript.self, from: data)
            .messages.map(\.chat)
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        let body = try BridgeCoding.encoder.encode(BRRename(title: title))
        _ = try await http.send(builder.request(.patch, "/sessions/\(sessionID)", body: body))
    }

    public func forkSession(_ sessionID: String) async throws -> AgentSession {
        let data = try await http.send(builder.request(.post, "/sessions/\(sessionID)/fork"))
        return try BridgeCoding.decoder.decode(BRSession.self, from: data).session
    }

    public func clearConversation(_ sessionID: String) async throws {
        _ = try await http.send(builder.request(.post, "/sessions/\(sessionID)/clear"))
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        let data = try await http.send(builder.request(.get, "/sessions/\(sessionID)"))
        return try BridgeCoding.decoder.decode(BRSession.self, from: data).messages.map(\.chat)
    }

    /// Bridges predating the command catalog answer 404, which decodes to an empty list rather
    /// than an error — the app then shows only its own actions.
    public func availableCommands(directory: String?) async throws -> [AgentCommand] {
        let query = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        guard let data = try? await http.send(builder.request(.get, "/commands", query: query)),
            let commands = try? BridgeCoding.decoder.decode([BRLenient<AgentCommand>].self, from: data)
        else { return [] }
        return commands.compactMap(\.value)
    }

    /// The bridge reads the CLI's own transcripts, which are already on disk and already the truth
    /// about what happened, so search runs where the words are rather than over anything this
    /// client had to fetch first. A bridge too old to have the route answers 404 and is reported as
    /// a server that cannot search — never as one that found nothing.
    public func searchTranscripts(_ query: String, limit: Int) async throws
        -> TranscriptSearchResult
    {
        let data = try await http.send(
            builder.request(
                .get, "/search",
                query: [
                    URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]))
        let response = try BridgeCoding.decoder.decode(BRSearch.self, from: data)
        return TranscriptSearchResult(
            hits: response.hits.map {
                TranscriptSearchHit(
                    sessionID: $0.sessionID, title: $0.title, directory: $0.directory,
                    updatedAt: $0.updatedAt,
                    matches: $0.matches.map {
                        TranscriptMatch(
                            kind: $0.kind, role: $0.role == "assistant" ? .assistant : .user,
                            text: $0.text, at: $0.at)
                    },
                    total: $0.total)
            },
            scanned: response.scanned, truncated: response.truncated)
    }

    public func goal(for sessionID: String) async throws -> SessionGoal? {
        let data = try await http.send(builder.request(.get, "/sessions/\(sessionID)"))
        return try BridgeCoding.decoder.decode(BRSession.self, from: data).goal?.goal
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        let attachments = prompt.attachments.compactMap { attachment -> BRSendAttachment? in
            guard let data = attachment.data, !data.isEmpty else { return nil }
            return BRSendAttachment(
                mime: attachment.mime, filename: attachment.filename,
                dataBase64: data.base64EncodedString())
        }
        let body = try BridgeCoding.encoder.encode(
            BRSend(
                text: prompt.text, model: prompt.model?.modelID, effort: prompt.reasoningEffort,
                attachments: attachments.isEmpty ? nil : attachments))
        _ = try await http.send(
            builder.request(.post, "/sessions/\(sessionID)/message", body: body))
    }

    /// Claude asks through the `AskUserQuestion` tool, which blocks on its own
    /// tool result rather than on a bridge request, so the pending ask lives in
    /// the transcript: the newest one still without a result is the one waiting
    /// on the user. Only the newest — an older unanswered ask has been overtaken
    /// by the conversation and must not bury the current one.
    public func pendingQuestions(
        in messages: [ChatMessage], sessionID: String
    ) -> [QuestionRequest] {
        QuestionRequest.awaitingAnswer(in: messages, sessionID: sessionID)
    }

    /// The bridge runs Claude headlessly, one process per turn, so there is no
    /// channel back into the pending tool call — the answer is delivered as the
    /// next user message, which is exactly how a person would answer anyway.
    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        let text = request.answerMessage(answers)
        guard !text.isEmpty else { return }
        try await send(SendPrompt(text: text), to: request.sessionID)
    }

    /// Dismissal is local: nothing is sent, so the agent is left exactly as it
    /// was and the user can still answer later from the transcript.
    public func rejectQuestion(_ request: QuestionRequest) async throws {}

    /// One multiplexed `/stream` socket per server when the bridge speaks proto 2 — every open
    /// conversation and list shares it, and a reconnect replays rather than refetches. An older
    /// bridge gets the per-session `/events` route it has always had.
    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let shared = stream
        return AsyncThrowingStream { continuation in
            let task = Task {
                if await shared.supportsStream() {
                    do {
                        for try await event in await shared.sessionEvents(sessionID) {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }
                await Self.legacyEvents(
                    for: sessionID, builder: self.builder, http: self.http,
                    continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func legacyEvents(
        for sessionID: String, builder: RequestBuilder, http: HTTPClient,
        continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation
    ) async {
        let stream: AsyncThrowingStream<SSEvent, Error>
        do {
            stream = http.serverSentEvents(
                try builder.eventStreamRequest("/sessions/\(sessionID)/events"))
        } catch {
            continuation.finish(throwing: error)
            return
        }
        var decoder = BridgeEventDecoder()
        do {
            for try await sse in stream {
                if let event = decoder.decode(sse) { continuation.yield(event) }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    public func availableModels() async throws -> [ModelInfo] { Self.models }
    public func defaultModel() async throws -> ModelSelection? {
        Self.models.first.map { ModelSelection(providerID: $0.providerID, modelID: $0.id) }
    }

    /// Newer bridges expose a two-field usage route; older ones require
    /// decoding the whole session transcript for the same numbers.
    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? {
        if let data = try? await http.send(
            builder.request(.get, "/sessions/\(sessionID)/usage")),
            let summary = try? BridgeCoding.decoder.decode(BRUsageSummary.self, from: data)
        {
            guard summary.costUSD != nil || summary.tokens != nil else { return nil }
            return AgentUsage(costUSD: summary.costUSD, tokens: summary.tokens)
        }
        let data = try await http.send(builder.request(.get, "/sessions/\(sessionID)"))
        let session = try BridgeCoding.decoder.decode(BRSession.self, from: data)
        guard session.lastCostUSD != nil || session.lastTokens != nil else { return nil }
        return AgentUsage(costUSD: session.lastCostUSD, tokens: session.lastTokens)
    }

    /// What the whole conversation cost, read by the bridge out of the CLI's own transcript. A
    /// bridge too old to have the route simply has nothing to say, and the client falls back to
    /// the last turn.
    public func sessionSpend(_ sessionID: String) async throws -> SessionSpendReport? {
        guard let data = try? await http.send(
            builder.request(.get, "/sessions/\(sessionID)/spend"))
        else { return nil }
        return try? BridgeCoding.decoder.decode(SessionSpendReport.self, from: data)
    }

    public func usageQuota() async throws -> UsageQuota? {
        let data = try await http.send(builder.request(.get, "/usage"))
        let snapshot = try BridgeCoding.decoder.decode(BRUsage.self, from: data)
        guard snapshot.live, !snapshot.gauges.isEmpty else { return nil }
        return UsageQuota(
            providerName: snapshot.providerName,
            subtitle: snapshot.subtitle,
            source: snapshot.source,
            live: snapshot.live,
            gauges: snapshot.gauges.map {
                UsageQuota.Gauge(
                    key: $0.key, label: $0.label, fraction: $0.fraction,
                    resetsAt: $0.resetsAt, trustedReset: $0.trustedReset,
                    usedUSD: $0.usedUSD, limitUSD: $0.limitUSD)
            },
            details: snapshot.details.map { UsageQuota.Detail(key: $0.key, value: $0.value) })
    }

    /// Every other provider this machine holds an account for, one bridge route each. Older
    /// bridges don't serve these routes; any failure or non-live snapshot reads as absence.
    public func additionalUsageQuotas() async throws -> [UsageQuota] {
        var quotas: [UsageQuota] = []
        for route in ["/usage/grok", "/usage/opencode"] {
            guard let data = try? await http.send(builder.request(.get, route)),
                let snapshot = try? BridgeCoding.decoder.decode(BRUsage.self, from: data),
                snapshot.live, !snapshot.gauges.isEmpty
            else { continue }
            quotas.append(
                UsageQuota(
                    providerName: snapshot.providerName,
                    subtitle: snapshot.subtitle,
                    source: snapshot.source,
                    live: snapshot.live,
                    gauges: snapshot.gauges.map {
                        UsageQuota.Gauge(
                            key: $0.key, label: $0.label, fraction: $0.fraction,
                            resetsAt: $0.resetsAt, trustedReset: $0.trustedReset,
                            usedUSD: $0.usedUSD, limitUSD: $0.limitUSD)
                    },
                    details: snapshot.details.map { UsageQuota.Detail(key: $0.key, value: $0.value) }))
        }
        return quotas
    }
}

private struct BRSearch: Decodable {
    struct Match: Decodable {
        let role: String
        let kind: String
        let text: String
        let at: Date?
    }

    struct Hit: Decodable {
        let sessionID: String
        let title: String
        let directory: String?
        let updatedAt: Date
        let matches: [Match]
        let total: Int
    }

    let hits: [Hit]
    let scanned: Int
    let truncated: Bool
}

private struct BRUsage: Decodable {
    struct Gauge: Decodable {
        let key: String
        let label: String
        let fraction: Double
        let resetsAt: Date?
        let trustedReset: Bool
        let usedUSD: Double?
        let limitUSD: Double?
    }
    struct Detail: Decodable {
        let key: String
        let value: String
    }
    let providerName: String
    let subtitle: String
    let source: String
    let live: Bool
    let gauges: [Gauge]
    let details: [Detail]
}

enum BridgeCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// Session metadata fields (`model`, `effort`, timestamps) are optional with fallbacks so a
/// single version-skewed field from an older or newer bridge can't fail the whole session list.
struct BRSummary: Decodable {
    let id: String
    let title: String
    let directory: String?
    let model: String?
    let effort: String?
    let createdAt: Date?
    let updatedAt: Date?
    let active: Bool?
    let agents: Int?
    let agentTask: String?

    var session: AgentSession {
        AgentSession(
            id: id, agentType: .claudeCode, title: title, directory: directory,
            createdAt: createdAt ?? updatedAt ?? .distantPast,
            updatedAt: updatedAt ?? createdAt ?? .distantPast, isActive: active,
            model: model, reasoningEffort: (effort?.isEmpty ?? true) ? nil : effort,
            activeAgents: agents, agentTask: agentTask)
    }
}

/// Decodes to `nil` instead of throwing when a single array element is malformed, so one
/// undecodable session summary is skipped rather than failing the entire `/sessions` decode.
struct BRLenient<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct BRSession: Decodable {
    let id: String
    let title: String
    let directory: String?
    let model: String?
    let effort: String?
    let createdAt: Date?
    let updatedAt: Date?
    let claudeSessionID: String?
    let messages: [BRMessage]
    let lastCostUSD: Double?
    let lastTokens: Int?
    let goal: BRGoal?

    var session: AgentSession {
        AgentSession(
            id: id, agentType: .claudeCode, title: title, directory: directory,
            createdAt: createdAt ?? updatedAt ?? .distantPast,
            updatedAt: updatedAt ?? createdAt ?? .distantPast,
            model: model, reasoningEffort: (effort?.isEmpty ?? true) ? nil : effort)
    }
}

struct BRGoal: Decodable {
    let condition: String
    let met: Bool?
    let failed: Bool?
    let reason: String?
    let iterations: Int?
    let durationMs: Double?
    let tokens: Int?
    let updatedAt: Date?

    var goal: SessionGoal {
        SessionGoal(
            condition: condition, isMet: met ?? false, didFail: failed ?? false, reason: reason,
            iterations: iterations, duration: durationMs.map { $0 / 1000 }, tokens: tokens,
            updatedAt: updatedAt)
    }
}

struct BRMessage: Decodable {
    let id: String
    let role: String
    let parts: [BRPart]
    let createdAt: Date

    /// Duplicate part ids (the bridge assigns text parts the fixed id "text")
    /// get an index suffix so `messageID:partID` row identifiers stay unique. The
    /// suffix scheme ("text", "text-1", …) mirrors `BridgeEventDecoder`'s delta
    /// routing so streamed tokens and full-message upserts converge on the same part.
    var chat: ChatMessage {
        var counts: [String: Int] = [:]
        let uniqueParts = parts.map { raw -> MessagePart in
            let part = raw.part
            let seen = counts[part.id, default: 0]
            counts[part.id] = seen + 1
            return seen == 0 ? part : MessagePart(id: "\(part.id)-\(seen)", kind: part.kind)
        }
        return ChatMessage(
            id: id, role: MessageRole(rawValue: role) ?? .assistant, agentType: .claudeCode,
            parts: uniqueParts, createdAt: createdAt)
    }
}

struct BRPart: Decodable {
    let kind: String
    let text: String?
    let tool: BRTool?
    let file: BRFile?
    let compaction: BRCompaction?

    var part: MessagePart {
        switch kind {
        case "tool":
            if let tool { return MessagePart(id: tool.id, kind: .tool(tool.toolCall)) }
        case "reasoning":
            return MessagePart(id: "reasoning", kind: .reasoning(text ?? ""))
        case "file":
            if let file { return MessagePart(id: "file", kind: .file(file.reference)) }
        case "compaction":
            if let compaction {
                return MessagePart(id: "compaction", kind: .compaction(compaction.compaction))
            }
        default:
            break
        }
        return MessagePart(id: "text", kind: .text(text ?? ""))
    }
}

struct BRCompaction: Decodable {
    let trigger: String?
    let tokensBefore: Int?
    let tokensAfter: Int?
    let durationMs: Double?
    let preservedMessages: Int?
    let summary: String?

    var compaction: Compaction {
        Compaction(
            trigger: trigger.flatMap(Compaction.Trigger.init(rawValue:)),
            tokensBefore: tokensBefore, tokensAfter: tokensAfter,
            duration: durationMs.map { $0 / 1000 },
            preservedMessageCount: preservedMessages,
            summary: summary?.isEmpty == true ? nil : summary)
    }
}

struct BRFile: Decodable {
    let path: String?
    let mime: String?
    let filename: String?
    let url: String?

    var reference: FileReference {
        FileReference(path: path, mime: mime, url: url, filename: filename)
    }
}

struct BRTool: Decodable {
    let id: String
    let name: String
    let input: String
    let output: String?
    let status: String

    var toolCall: ToolCall {
        var parsed: JSONValue?
        if let data = input.data(using: .utf8) {
            parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        return ToolCall(
            id: id, name: name, status: ToolStatus(rawValue: status) ?? .running,
            input: parsed, output: output, title: name)
    }
}

struct BRCreate: Encodable {
    let title: String?
    let directory: String?
    let model: String?
    let effort: String?
}

struct BRUsageSummary: Decodable {
    let costUSD: Double?
    let tokens: Int?
}

struct BRSubagent: Decodable {
    let id: String
    let title: String
    let agentType: String?
    let toolUseID: String?
    let updatedAt: Date
    let active: Bool
    let completed: Bool?
    let startedAt: Date?
    let toolCount: Int?
    let currentTool: String?
    let todosDone: Int?
    let todosTotal: Int?
    let currentTodo: String?

    var summary: SubagentSummary {
        SubagentSummary(
            id: id, title: title, agentType: agentType, toolUseID: toolUseID,
            updatedAt: updatedAt, isActive: active, isCompleted: completed ?? false,
            startedAt: startedAt, toolCount: toolCount, currentTool: currentTool,
            todosDone: todosDone, todosTotal: todosTotal, currentTodo: currentTodo)
    }
}

struct BRSubagentTranscript: Decodable {
    let id: String
    let messages: [BRMessage]
}

struct BRRename: Encodable {
    let title: String
}

struct BRSend: Encodable {
    let text: String
    let model: String?
    let effort: String?
    let attachments: [BRSendAttachment]?
}

struct BRSendAttachment: Encodable {
    let mime: String
    let filename: String?
    let dataBase64: String
}

/// Decodes claude-bridge SSE payloads into `BackendEvent`s. Stateful because the bridge
/// streams each assistant text block as a run of `delta` events that carry no part id, so the
/// decoder tracks, per message, which text part is currently streaming and routes deltas to it —
/// the `text`/`text-N` id it assigns matches `BRMessage.chat`'s dedup so a delta and a later
/// full-message upsert land on the same part instead of piling new text onto the first block.
/// Public so recorded bridge fixtures can be replayed through the real decoder in tests.
extension ClaudeCodeBackend: SessionListStreaming, SubagentStreaming {
    /// Never nil: a bridge that cannot push yet is waited on, not written off. The moment the
    /// server starts speaking proto 2 — an upgrade mid-flight — subscribers get `.invalidated`
    /// (refetch what you render) and then live changes, with no relaunch anywhere.
    public func sessionListChanges() async -> AsyncStream<SessionListChange>? {
        let shared = stream
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    guard await shared.supportsStream() else {
                        try? await Task.sleep(for: .seconds(65))
                        continue
                    }
                    continuation.yield(.invalidated)
                    for await change in await shared.listEvents() {
                        switch change {
                        case .upsert(let session): continuation.yield(.upsert(session))
                        case .remove(let id): continuation.yield(.remove(id))
                        case .invalidated: continuation.yield(.invalidated)
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func subagentChanges(for sessionID: String) async -> AsyncStream<[SubagentSummary]>? {
        let shared = stream
        return AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    guard await shared.supportsStream() else {
                        try? await Task.sleep(for: .seconds(65))
                        continue
                    }
                    for await agents in await shared.agentEvents(sessionID) {
                        continuation.yield(agents)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public struct BridgeEventDecoder {
    private var textStreams: [String: TextStream] = [:]

    public init() {}

    private struct TextStream {
        var count = 0
        var currentPartID: String?
        var awaitingNewPart = true
    }

    public mutating func decode(_ event: SSEvent) -> BackendEvent? {
        guard let data = event.data.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch object["type"] as? String {
        case "message":
            guard
                let messageData = try? JSONSerialization.data(
                    withJSONObject: object["message"] ?? [:]),
                let message = try? BridgeCoding.decoder.decode(BRMessage.self, from: messageData)
            else { return nil }
            let chat = message.chat
            syncTextStream(with: chat)
            return .messageUpserted(chat, replaceParts: true)
        case "delta":
            guard let messageID = object["messageID"] as? String,
                let delta = object["delta"] as? String
            else { return nil }
            return .partTextDelta(
                messageID: messageID, partID: openTextPartID(in: messageID), delta: delta)
        case "tool":
            guard let messageID = object["messageID"] as? String,
                let toolData = try? JSONSerialization.data(withJSONObject: object["tool"] ?? [:]),
                let tool = try? BridgeCoding.decoder.decode(BRTool.self, from: toolData)
            else { return nil }
            closeTextPart(in: messageID)
            return .partUpserted(
                messageID: messageID, MessagePart(id: tool.id, kind: .tool(tool.toolCall)))
        case "status":
            switch object["status"] as? String {
            case "running": return .status(.running)
            default: return .status(.idle)
            }
        case "compaction":
            switch object["phase"] as? String {
            case "started": return .compaction(CompactionActivity(startedAt: Date()))
            case "failed":
                return .compaction(
                    CompactionActivity(
                        startedAt: Date(),
                        failure: object["error"] as? String
                            ?? CompactionActivity.unexplainedFailure))
            default: return .compaction(nil)
            }
        case "goal":
            guard let raw = object["goal"] else { return .goal(nil) }
            guard let goalData = try? JSONSerialization.data(withJSONObject: raw),
                let goal = try? BridgeCoding.decoder.decode(BRGoal.self, from: goalData)
            else { return .goal(nil) }
            return .goal(goal.goal)
        case "error":
            return .failure(BackendFailure(message: object["error"] as? String ?? "error"))
        default:
            return nil
        }
    }

    /// The id of the text part the next delta belongs to. Opens a fresh part — using the same
    /// `text`/`text-N` numbering as `BRMessage.chat` — when the message has no open text part yet
    /// or a tool closed the previous one; otherwise keeps appending to the currently open part.
    private mutating func openTextPartID(in messageID: String) -> String {
        var stream = textStreams[messageID] ?? TextStream()
        if stream.awaitingNewPart || stream.currentPartID == nil {
            let id = stream.count == 0 ? "text" : "text-\(stream.count)"
            stream.count += 1
            stream.currentPartID = id
            stream.awaitingNewPart = false
        }
        let id = stream.currentPartID ?? "text"
        textStreams[messageID] = stream
        return id
    }

    /// Marks the message's open text part as finished so the next delta starts a new part,
    /// mirroring how a tool call interrupts an assistant text block.
    private mutating func closeTextPart(in messageID: String) {
        var stream = textStreams[messageID] ?? TextStream()
        stream.awaitingNewPart = true
        textStreams[messageID] = stream
    }

    /// Re-derives the open text part from a full message snapshot so deltas that follow keep
    /// routing to the newest text part even when the tool/part structure arrived via an upsert
    /// rather than discrete `tool`/`delta` events. A snapshot ending in a non-text part leaves
    /// the stream awaiting a fresh part for the next delta.
    private mutating func syncTextStream(with message: ChatMessage) {
        let textPartIDs = message.parts.compactMap { part -> String? in
            if case .text = part.kind { return part.id }
            return nil
        }
        var stream = textStreams[message.id] ?? TextStream()
        stream.count = textPartIDs.count
        stream.currentPartID = textPartIDs.last
        stream.awaitingNewPart = textPartIDs.isEmpty || message.parts.last?.id != textPartIDs.last
        textStreams[message.id] = stream
    }
}

/// The bridge serves the server user's home directory over `/files`, which
/// powers the app's directory picker and file browser for Claude sessions.
/// Diffs, find, and providers have no bridge equivalent yet.
extension ClaudeCodeBackend: FileBrowsingBackend {
    public func listFiles(path: String?) async throws -> [FileNode] {
        let data = try await http.send(
            builder.request(
                .get, "/files", query: [URLQueryItem(name: "path", value: path ?? ".")]))
        return try BridgeCoding.decoder.decode([BRFileEntry].self, from: data)
            .map { FileNode(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) }
    }

    /// Attachment bytes ride the bridge's own auth, so a private tailnet URL
    /// the client could not open directly still renders inline.
    public func attachmentData(_ file: FileReference) async throws -> Data {
        guard let url = file.url, url.hasPrefix("/") else {
            throw AgentError.unsupported("attachment without a bridge url")
        }
        let components = URLComponents(string: url)
        return try await http.send(
            builder.request(
                .get, components?.path ?? url, query: components?.queryItems ?? []))
    }

    public func fileContent(path: String) async throws -> String {
        let data = try await http.send(
            builder.request(
                .get, "/files/content", query: [URLQueryItem(name: "path", value: path)]))
        return try BridgeCoding.decoder.decode(BRFileContent.self, from: data).content
    }

    public func diff(sessionID: String) async throws -> [FileDiff] { [] }
    public func find(pattern: String) async throws -> [String] { [] }
    public func providers() async throws -> [Provider] { [] }
}

struct BRStatus: Decodable {
    let agent: String?
    let model: String?
    let version: String?
}

struct BRFileEntry: Decodable {
    let path: String
    let name: String
    let isDirectory: Bool
}

struct BRFileContent: Decodable {
    let path: String
    let content: String
}

/// The CLI's sign-in is a terminal program; the bridge runs it on a pseudo-terminal and relays the
/// two halves a person has to supply — opening a link, and returning the code it produces.
extension ClaudeCodeBackend: AuthenticatingBackend {
    public func authStatus() async throws -> ServerAuth {
        try await decodeAuth(http.send(builder.request(.get, "/auth")))
    }

    public func beginSignIn() async throws -> ServerAuth {
        try await decodeAuth(http.send(builder.request(.post, "/auth/login")))
    }

    public func submitSignInCode(_ code: String) async throws -> ServerAuth {
        let body = try BridgeCoding.encoder.encode(BRAuthCode(code: code))
        return try await decodeAuth(http.send(builder.request(.post, "/auth/code", body: body)))
    }

    public func cancelSignIn() async throws {
        _ = try? await http.send(builder.request(.post, "/auth/cancel"))
    }

    private func decodeAuth(_ data: Data) throws -> ServerAuth {
        try BridgeCoding.decoder.decode(ServerAuth.self, from: data)
    }
}

struct BRAuthCode: Encodable {
    let code: String
}

/// The bridge is installed from source and can pull, rebuild and restart itself, so a client can
/// keep a server current without anyone opening a terminal on the machine it runs on.
extension ClaudeCodeBackend: SelfUpdatingBackend {
    public func updateStatus(checkingRemote: Bool) async throws -> ServerUpdate {
        let data = try await http.send(
            builder.request(
                .get, "/update",
                query: checkingRemote ? [] : [URLQueryItem(name: "check", value: "false")]))
        return try BridgeCoding.decoder.decode(ServerUpdate.self, from: data)
    }

    public func startUpdate() async throws -> ServerUpdate {
        do {
            let data = try await http.send(builder.request(.post, "/update"))
            return try BridgeCoding.decoder.decode(ServerUpdate.self, from: data)
        } catch AgentError.http(let status, let body) where status == 409 {
            guard let data = body.data(using: .utf8),
                let refused = try? BridgeCoding.decoder.decode(ServerUpdate.self, from: data)
            else { throw AgentError.unsupported("The server refused to update itself.") }
            return refused
        }
    }
}

extension ClaudeCodeBackend {
    public func registerLiveActivity(
        _ registration: LiveActivityRegistration, for sessionID: String
    ) async throws {
        let body = try BridgeCoding.encoder.encode(registration)
        _ = try await http.send(
            builder.request(.post, "/sessions/\(sessionID)/live-activity", body: body))
    }
}

extension ClaudeCodeBackend {
    public func registerDeviceToken(_ registration: DevicePushRegistration) async throws {
        let body = try BridgeCoding.encoder.encode(registration)
        _ = try await http.send(builder.request(.post, "/push/device", body: body))
    }

    public func unregisterDeviceToken(_ registration: DevicePushRegistration) async throws {
        let body = try BridgeCoding.encoder.encode(registration)
        _ = try await http.send(builder.request(.post, "/push/device/unregister", body: body))
    }
}
