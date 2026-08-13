import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct OpenCodeClient: Sendable {
    let builder: RequestBuilder
    let http: HTTPClient

    public init(config: ServerConfig, http: HTTPClient? = nil) {
        self.builder = RequestBuilder(config: config)
        self.http = http ?? HTTPClient(policy: config.policy, logger: AgentLog.logger("opencode"))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw AgentError.decoding("\(T.self): \(error)")
        }
    }

    func health() async throws -> OCHealth {
        try decode(await http.send(builder.request(.get, "/global/health")))
    }

    func listSessions() async throws -> [OCSession] {
        try decode(await http.send(builder.request(.get, "/session")))
    }

    /// `/session` answers only for the project the server was launched in unless
    /// a worktree is named, so account-wide history has to be walked project by
    /// project.
    func listSessions(directory: String) async throws -> [OCSession] {
        try decode(
            await http.send(builder.request(.get, "/session", query: directoryQuery(directory))))
    }

    func projects() async throws -> [OCProject] {
        try decode(await http.send(builder.request(.get, "/project")))
    }

    /// The working directory is a QUERY parameter on opencode's session
    /// routes — a `directory` body field is silently ignored and the session
    /// lands in the server's own cwd. The title, by contrast, is a BODY field
    /// on `POST /session`; when omitted the server auto-titles the session.
    func createSession(title: String?, directory: String?) async throws -> OCSession {
        let body = try JSONCoding.encoder.encode(OCSessionCreateRequest(title: title))
        return try decode(
            await http.send(
                builder.request(
                    .post, "/session", query: directoryQuery(directory), body: body)))
    }

    /// Question routes are directory-scoped like `/event`: the request id is
    /// only resolvable in the workspace the session runs in.
    func answerQuestion(requestID: String, directory: String?, answers: [[String]]) async throws {
        let body = try JSONEncoder().encode(["answers": answers])
        try await http.send(
            builder.request(
                .post, "/question/\(requestID)/reply",
                query: directoryQuery(directory), body: body))
    }

    func rejectQuestion(requestID: String, directory: String?) async throws {
        try await http.send(
            builder.request(
                .post, "/question/\(requestID)/reject",
                query: directoryQuery(directory), body: Data("{}".utf8)))
    }

    func pendingQuestions(directory: String?) async throws -> [OCQuestionRequestDTO] {
        try decode(
            await http.send(
                builder.request(.get, "/question", query: directoryQuery(directory))))
    }

    private func directoryQuery(_ directory: String?) -> [URLQueryItem] {
        directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
    }

    func deleteSession(_ sessionID: String) async throws {
        try await http.send(builder.request(.delete, "/session/\(sessionID)"))
    }

    /// A single session by id. Used when the default project listing does not include it (e.g. a
    /// chat rooted at `$HOME` while the server was launched from a repo) so the event stream can
    /// still learn its workspace directory.
    func session(_ sessionID: String) async throws -> OCSession {
        try decode(await http.send(builder.request(.get, "/session/\(sessionID)")))
    }

    func messages(sessionID: String) async throws -> [OCMessageEnvelope] {
        try decode(await http.send(builder.request(.get, "/session/\(sessionID)/message")))
    }

    func promptAsync(sessionID: String, request: OCPromptRequest) async throws {
        let body = try JSONCoding.encoder.encode(request)
        try await http.send(
            builder.request(.post, "/session/\(sessionID)/prompt_async", body: body))
    }

    func commands() async throws -> [OCCommand] {
        try decode(await http.send(builder.request(.get, "/command")))
    }

    /// Unlike `prompt_async`, opencode has no non-blocking command route: this returns only once
    /// the turn it starts has finished.
    func runCommand(sessionID: String, directory: String?, request: OCCommandRequest) async throws {
        let body = try JSONCoding.encoder.encode(request)
        try await http.send(
            builder.request(
                .post, "/session/\(sessionID)/command", query: directoryQuery(directory),
                body: body))
    }

    func abort(sessionID: String) async throws {
        try await http.send(
            builder.request(.post, "/session/\(sessionID)/abort", body: Data("{}".utf8)))
    }

    /// Compacts a session: the server summarizes the conversation and carries the summary forward.
    /// The route blocks until the whole compaction turn has ended, so it is dispatched rather than
    /// awaited by callers that must not sit behind minutes of summarizing.
    func summarize(sessionID: String, providerID: String, modelID: String) async throws {
        struct Body: Encodable {
            let providerID: String
            let modelID: String
        }
        let body = try JSONCoding.encoder.encode(Body(providerID: providerID, modelID: modelID))
        try await http.send(
            builder.request(.post, "/session/\(sessionID)/summarize", body: body))
    }

    func respondPermission(sessionID: String, permissionID: String, response: String) async throws {
        let body = try JSONCoding.encoder.encode(["response": response])
        try await http.send(
            builder.request(.post, "/session/\(sessionID)/permissions/\(permissionID)", body: body))
    }

    func diff(sessionID: String) async throws -> [OCDiff] {
        try decode(await http.send(builder.request(.get, "/session/\(sessionID)/diff")))
    }

    func files(path: String) async throws -> [OCFileNode] {
        try decode(
            await http.send(
                builder.request(.get, "/file", query: [URLQueryItem(name: "path", value: path)])))
    }

    func fileContent(path: String) async throws -> OCFileContent {
        try decode(
            await http.send(
                builder.request(
                    .get, "/file/content", query: [URLQueryItem(name: "path", value: path)])))
    }

    func find(pattern: String) async throws -> [OCFindMatch] {
        try decode(
            await http.send(
                builder.request(
                    .get, "/find", query: [URLQueryItem(name: "pattern", value: pattern)])))
    }

    func providers() async throws -> OCProvidersResponse {
        try decode(await http.send(builder.request(.get, "/config/providers")))
    }

    /// `/event` is directory-scoped: a session created in another workspace
    /// emits nothing on the unscoped stream, so subscribers must pass the
    /// session's directory.
    func eventStream(directory: String?) -> AsyncThrowingStream<SSEvent, Error> {
        do {
            return http.serverSentEvents(
                try builder.eventStreamRequest("/event", query: directoryQuery(directory)))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
