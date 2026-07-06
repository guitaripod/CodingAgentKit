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

    func createSession() async throws -> OCSession {
        try decode(await http.send(builder.request(.post, "/session")))
    }

    func deleteSession(_ sessionID: String) async throws {
        try await http.send(builder.request(.delete, "/session/\(sessionID)"))
    }

    func messages(sessionID: String) async throws -> [OCMessageEnvelope] {
        try decode(await http.send(builder.request(.get, "/session/\(sessionID)/message")))
    }

    func promptAsync(sessionID: String, request: OCPromptRequest) async throws {
        let body = try JSONCoding.encoder.encode(request)
        try await http.send(
            builder.request(.post, "/session/\(sessionID)/prompt_async", body: body))
    }

    func abort(sessionID: String) async throws {
        try await http.send(
            builder.request(.post, "/session/\(sessionID)/abort", body: Data("{}".utf8)))
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

    func eventStream() -> AsyncThrowingStream<SSEvent, Error> {
        do {
            return http.serverSentEvents(try builder.eventStreamRequest("/event"))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
