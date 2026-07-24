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
        supportsAttachments: true,
        supportsAbort: true,
        supportsSessionUsage: false,
        supportsQuestions: true
    )

    let client: OpenCodeClient
    private let directories = SessionDirectoryCache()

    public init(config: ServerConfig) {
        self.client = OpenCodeClient(config: config)
    }

    public init(client: OpenCodeClient) {
        self.client = client
    }

    /// opencode scopes `/event` and `/question` by workspace directory, so
    /// per-session calls need the session's directory. Cached; refreshed from
    /// the session list on miss.
    private actor SessionDirectoryCache {
        private var directories: [String: String] = [:]

        func directory(for sessionID: String, client: OpenCodeClient) async -> String? {
            if let cached = directories[sessionID] { return cached }
            if let sessions = try? await client.listSessions() {
                for session in sessions {
                    if let directory = session.directory {
                        directories[session.id] = directory
                    }
                }
            }
            return directories[sessionID]
        }

        func record(sessionID: String, directory: String?) {
            guard let directory else { return }
            directories[sessionID] = directory
        }
    }

    public func health() async throws -> ServerHealth {
        let health = try await client.health()
        return ServerHealth(healthy: health.healthy, version: health.version)
    }

    public func listSessions() async throws -> [AgentSession] {
        try await client.listSessions().map(OpenCodeMapping.session)
    }

    public func createSession(title: String?, directory: String?) async throws -> AgentSession {
        let session = OpenCodeMapping.session(
            try await client.createSession(title: title, directory: directory))
        await directories.record(sessionID: session.id, directory: session.directory)
        return session
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await client.deleteSession(sessionID)
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
        AsyncThrowingStream { continuation in
            let task = Task {
                let directory = await directories.directory(for: sessionID, client: client)
                do {
                    for try await sse in client.eventStream(directory: directory) {
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

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        let directory = await directories.directory(for: request.sessionID, client: client)
        try await client.answerQuestion(
            requestID: request.id, directory: directory, answers: answers)
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        let directory = await directories.directory(for: request.sessionID, client: client)
        try await client.rejectQuestion(requestID: request.id, directory: directory)
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] {
        let directory = await directories.directory(for: sessionID, client: client)
        return try await client.pendingQuestions(directory: directory)
            .compactMap(OpenCodeMapping.question)
            .filter { $0.sessionID == sessionID }
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
                        providerID: provider.id,
                        capabilities: $0.value.capabilities.map { caps in
                            ModelCapabilities(
                                attachment: caps.attachment ?? false,
                                imageInput: caps.input?.image ?? false,
                                pdfInput: caps.input?.pdf ?? false)
                        })
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
