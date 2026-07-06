import AgentCore
import Foundation

public struct OpenCodeBackend: FileBrowsingBackend {
    public let agentType: AgentType = .openCode
    public let capabilities = BackendCapabilities(
        supportsFileBrowsing: true,
        supportsDiffs: true,
        supportsPermissions: true,
        supportsMultipleSessions: true,
        supportsModelSelection: true,
        supportsAttachments: true
    )

    let client: OpenCodeClient

    public init(config: ServerConfig) {
        self.client = OpenCodeClient(config: config)
    }

    public init(client: OpenCodeClient) {
        self.client = client
    }

    public func health() async throws -> ServerHealth {
        let health = try await client.health()
        return ServerHealth(healthy: health.healthy, version: health.version)
    }

    public func listSessions() async throws -> [AgentSession] {
        try await client.listSessions().map(OpenCodeMapping.session)
    }

    public func createSession(title: String?) async throws -> AgentSession {
        OpenCodeMapping.session(try await client.createSession())
    }

    public func messages(for sessionID: String) async throws -> [ChatMessage] {
        try await client.messages(sessionID: sessionID).map(OpenCodeMapping.message)
    }

    public func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        let model = prompt.model.map {
            OCModelInput(providerID: $0.providerID, modelID: $0.modelID)
        }
        var parts: [OCPartInput] = [.text(prompt.text)]
        for attachment in prompt.attachments {
            guard let url = Self.attachmentURL(attachment) else { continue }
            parts.append(.file(mime: attachment.mime, filename: attachment.filename, url: url))
        }
        let request = OCPromptRequest(parts: parts, model: model, agent: prompt.agent)
        try await client.promptAsync(sessionID: sessionID, request: request)
    }

    private static func attachmentURL(_ attachment: PromptAttachment) -> String? {
        if let url = attachment.url { return url }
        if let data = attachment.data {
            return "data:\(attachment.mime);base64,\(data.base64EncodedString())"
        }
        return nil
    }

    public func availableModels() async throws -> [ModelInfo] {
        try await providers().flatMap(\.models)
    }

    public func defaultModel() async throws -> ModelSelection? {
        for provider in try await providers() where provider.defaultModelID != nil {
            return ModelSelection(providerID: provider.id, modelID: provider.defaultModelID!)
        }
        return nil
    }

    public func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        let raw = client.eventStream()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await sse in raw {
                        if let event = OpenCodeEventDecoder.decode(sse, sessionID: sessionID) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func abort(sessionID: String) async throws {
        try await client.abort(sessionID: sessionID)
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        try await client.respondPermission(
            sessionID: permission.sessionID,
            permissionID: permission.id,
            response: decision.rawValue
        )
    }

    public func listFiles(path: String?) async throws -> [FileNode] {
        try await client.files(path: path ?? ".").map {
            FileNode(path: $0.path, name: $0.name, isDirectory: $0.type == "directory")
        }
    }

    public func fileContent(path: String) async throws -> String {
        try await client.fileContent(path: path).content
    }

    public func diff(sessionID: String) async throws -> [FileDiff] {
        try await client.diff(sessionID: sessionID).map {
            FileDiff(
                path: $0.file ?? "", additions: $0.additions ?? 0, deletions: $0.deletions ?? 0,
                patch: $0.patch)
        }
    }

    public func find(pattern: String) async throws -> [String] {
        try await client.find(pattern: pattern).compactMap { match in
            guard let path = match.path?.text else { return nil }
            if let line = match.lineNumber { return "\(path):\(line)" }
            return path
        }
    }

    public func providers() async throws -> [Provider] {
        let response = try await client.providers()
        return response.providers.map { provider in
            let models = (provider.models ?? [:])
                .map {
                    ModelInfo(
                        id: $0.value.id ?? $0.key, name: $0.value.name ?? $0.key,
                        providerID: provider.id)
                }
                .sorted { $0.id < $1.id }
            return Provider(
                id: provider.id,
                name: provider.name ?? provider.id,
                models: models,
                defaultModelID: response.default?[provider.id]
            )
        }
    }
}
