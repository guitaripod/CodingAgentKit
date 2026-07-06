import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct AgentAPIClient: Sendable {
    let builder: RequestBuilder
    let http: HTTPClient

    public init(config: ServerConfig, http: HTTPClient? = nil) {
        self.builder = RequestBuilder(config: config)
        self.http = http ?? HTTPClient(policy: config.policy, logger: AgentLog.logger("claudecode"))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw AgentError.decoding("\(T.self): \(error)")
        }
    }

    func messages() async throws -> [AAMessage] {
        let data = try await http.send(builder.request(.get, "/messages"))
        if let wrapped = try? JSONCoding.decoder.decode(AAMessagesResponse.self, from: data) {
            return wrapped.messages
        }
        return try decode(data)
    }

    func status() async throws -> AAStatus {
        try decode(await http.send(builder.request(.get, "/status")))
    }

    func sendMessage(content: String, type: String = "user") async throws {
        let body = try JSONCoding.encoder.encode(AASendMessage(content: content, type: type))
        try await http.send(builder.request(.post, "/message", body: body))
    }

    func eventStream() -> AsyncThrowingStream<SSEvent, Error> {
        do {
            return http.serverSentEvents(try builder.eventStreamRequest("/events"))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
