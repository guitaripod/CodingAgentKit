import AgentCore
import Foundation

public struct ClaudeCodeBackend: CodingAgentBackend {
    public let agentType: AgentType = .claudeCode
    public let capabilities = BackendCapabilities(
        supportsFileBrowsing: false,
        supportsDiffs: false,
        supportsPermissions: false,
        supportsMultipleSessions: true,
        supportsModelSelection: true,
        supportsAttachments: false,
        supportsReasoningEffort: true,
        supportsClearing: true,
        supportsForking: true,
        supportsAbort: true,
        supportsSessionUsage: true,
        supportsRenaming: true,
        supportsSubagents: true
    )

    public static let models: [ModelInfo] = [
        ModelInfo(id: "fable", name: "Fable", providerID: "anthropic"),
        ModelInfo(id: "opus", name: "Opus", providerID: "anthropic"),
        ModelInfo(id: "sonnet", name: "Sonnet", providerID: "anthropic"),
        ModelInfo(id: "haiku", name: "Haiku", providerID: "anthropic"),
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
        return try BridgeCoding.decoder.decode([BRSummary].self, from: data).map(\.session)
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
        let body = try BridgeCoding.encoder.encode(
            BRSend(text: prompt.text, model: prompt.model?.modelID, effort: prompt.reasoningEffort))
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
                do {
                    for try await sse in stream {
                        if let event = BridgeEventDecoder.decode(sse) { continuation.yield(event) }
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

    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? {
        let data = try await http.send(builder.request(.get, "/sessions/\(sessionID)"))
        let session = try BridgeCoding.decoder.decode(BRSession.self, from: data)
        guard session.lastCostUSD != nil || session.lastTokens != nil else { return nil }
        return AgentUsage(costUSD: session.lastCostUSD, tokens: session.lastTokens)
    }
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

struct BRSummary: Decodable {
    let id: String
    let title: String
    let directory: String?
    let model: String
    let effort: String
    let createdAt: Date
    let updatedAt: Date
    let active: Bool?

    var session: AgentSession {
        AgentSession(
            id: id, agentType: .claudeCode, title: title, directory: directory,
            createdAt: createdAt, updatedAt: updatedAt, isActive: active)
    }
}

struct BRSession: Decodable {
    let id: String
    let title: String
    let directory: String?
    let model: String
    let effort: String
    let createdAt: Date
    let updatedAt: Date
    let claudeSessionID: String?
    let messages: [BRMessage]
    let lastCostUSD: Double?
    let lastTokens: Int?

    var session: AgentSession {
        AgentSession(
            id: id, agentType: .claudeCode, title: title, directory: directory,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

struct BRMessage: Decodable {
    let id: String
    let role: String
    let parts: [BRPart]
    let createdAt: Date

    /// Duplicate part ids (the bridge assigns text parts the fixed id "text")
    /// get an index suffix so `messageID:partID` row identifiers stay unique;
    /// the first occurrence keeps its base id so streaming deltas still route.
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
}

enum BridgeEventDecoder {
    static func decode(_ event: SSEvent) -> BackendEvent? {
        guard let data = event.data.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        switch object["type"] as? String {
        case "message":
            guard let messageData = try? JSONSerialization.data(withJSONObject: object["message"] ?? [:]),
                let message = try? BridgeCoding.decoder.decode(BRMessage.self, from: messageData)
            else { return nil }
            return .messageUpserted(message.chat, replaceParts: true)
        case "delta":
            guard let messageID = object["messageID"] as? String,
                let delta = object["delta"] as? String
            else { return nil }
            return .partTextDelta(messageID: messageID, partID: "text", delta: delta)
        case "tool":
            guard let messageID = object["messageID"] as? String,
                let toolData = try? JSONSerialization.data(withJSONObject: object["tool"] ?? [:]),
                let tool = try? BridgeCoding.decoder.decode(BRTool.self, from: toolData)
            else { return nil }
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
}
