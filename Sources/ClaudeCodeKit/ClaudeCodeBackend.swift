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
        supportsRenaming: true,
        supportsSubagents: true,
        reportsMessageCompletion: false
    )

    private static let vision = ModelCapabilities(
        attachment: true, imageInput: true, pdfInput: true)

    public static let models: [ModelInfo] = [
        ModelInfo(id: "fable", name: "Fable", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "opus", name: "Opus", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic", capabilities: vision),
        ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic", capabilities: vision),
    ]

    public var reasoningEffortOptions: [String] { ["low", "medium", "high", "xhigh", "max"] }

    private let builder: RequestBuilder
    private let http: HTTPClient

    public init(config: ServerConfig) {
        self.builder = RequestBuilder(config: config)
        self.http = HTTPClient(policy: config.policy, logger: AgentLog.logger("claude-bridge"))
    }

    public func health() async throws -> ServerHealth {
        _ = try await http.send(builder.request(.get, "/health"))
        return ServerHealth(healthy: true, version: "claude")
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

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let stream: AsyncThrowingStream<SSEvent, Error>
        do {
            stream = http.serverSentEvents(
                try builder.eventStreamRequest("/sessions/\(sessionID)/events"))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
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
            continuation.onTermination = { _ in task.cancel() }
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
                    resetsAt: $0.resetsAt, trustedReset: $0.trustedReset)
            },
            details: snapshot.details.map { UsageQuota.Detail(key: $0.key, value: $0.value) })
    }

    /// Older bridges don't serve `/usage/grok`; treat any failure or non-live snapshot as absence.
    public func additionalUsageQuotas() async throws -> [UsageQuota] {
        guard let data = try? await http.send(builder.request(.get, "/usage/grok")),
            let snapshot = try? BridgeCoding.decoder.decode(BRUsage.self, from: data),
            snapshot.live, !snapshot.gauges.isEmpty
        else { return [] }
        return [
            UsageQuota(
                providerName: snapshot.providerName,
                subtitle: snapshot.subtitle,
                source: snapshot.source,
                live: snapshot.live,
                gauges: snapshot.gauges.map {
                    UsageQuota.Gauge(
                        key: $0.key, label: $0.label, fraction: $0.fraction,
                        resetsAt: $0.resetsAt, trustedReset: $0.trustedReset)
                },
                details: snapshot.details.map { UsageQuota.Detail(key: $0.key, value: $0.value) })
        ]
    }
}

private struct BRUsage: Decodable {
    struct Gauge: Decodable {
        let key: String
        let label: String
        let fraction: Double
        let resetsAt: Date?
        let trustedReset: Bool
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

    var session: AgentSession {
        AgentSession(
            id: id, agentType: .claudeCode, title: title, directory: directory,
            createdAt: createdAt ?? updatedAt ?? .distantPast,
            updatedAt: updatedAt ?? createdAt ?? .distantPast, isActive: active,
            model: model, reasoningEffort: (effort?.isEmpty ?? true) ? nil : effort)
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

    var session: AgentSession {
        AgentSession(
            id: id, agentType: .claudeCode, title: title, directory: directory,
            createdAt: createdAt ?? updatedAt ?? .distantPast,
            updatedAt: updatedAt ?? createdAt ?? .distantPast,
            model: model, reasoningEffort: (effort?.isEmpty ?? true) ? nil : effort)
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
            id: id, role: role == "user" ? .user : .assistant, agentType: .claudeCode,
            parts: uniqueParts, createdAt: createdAt)
    }
}

struct BRPart: Decodable {
    let kind: String
    let text: String?
    let tool: BRTool?

    var part: MessagePart {
        switch kind {
        case "tool":
            if let tool { return MessagePart(id: tool.id, kind: .tool(tool.toolCall)) }
        case "reasoning":
            return MessagePart(id: "reasoning", kind: .reasoning(text ?? ""))
        default:
            break
        }
        return MessagePart(id: "text", kind: .text(text ?? ""))
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

    var summary: SubagentSummary {
        SubagentSummary(
            id: id, title: title, agentType: agentType, toolUseID: toolUseID,
            updatedAt: updatedAt, isActive: active, isCompleted: completed ?? false)
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

struct BRFileEntry: Decodable {
    let path: String
    let name: String
    let isDirectory: Bool
}

struct BRFileContent: Decodable {
    let path: String
    let content: String
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
