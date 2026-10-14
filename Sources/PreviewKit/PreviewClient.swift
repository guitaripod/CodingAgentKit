import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The preview host on one Mac: it builds an app, runs it on a simulator it owns, and streams the
/// picture. Everything here is a question put to that machine; none of the work happens on this one.
public struct PreviewClient: Sendable {
    public static let defaultPort = 4300
    public static let username = "preview"

    private let builder: RequestBuilder
    private let http: HTTPClient

    public init(config: ServerConfig) {
        builder = RequestBuilder(config: config)
        http = HTTPClient(policy: config.policy, logger: AgentLog.logger("preview"))
    }

    /// A config for the host at `host`, on its own port.
    public static func config(
        host: String, port: Int = defaultPort, password: String?, policy: ConnectionPolicy = .default
    ) -> ServerConfig? {
        guard let url = URL(string: "http://\(host):\(port)") else { return nil }
        let credentials = password.map { BasicCredentials(username: username, password: $0) }
        return ServerConfig(baseURL: url, credentials: credentials, policy: policy)
    }

    public func status() async throws -> PreviewStatus {
        try decode(PreviewStatus.self, await http.send(builder.request(.get, "/status")))
    }

    public func doctor() async throws -> [DoctorCheck] {
        try decode([DoctorCheck].self, await http.send(builder.request(.get, "/doctor")))
    }

    public func startFix(_ fix: String) async throws -> FixJob {
        try decode(FixJob.self, await http.send(builder.request(.post, "/fixes/\(fix)")))
    }

    public func fix(_ id: String) async throws -> FixJob {
        try decode(FixJob.self, await http.send(builder.request(.get, "/fixes/\(id)")))
    }

    public func projects(in path: String) async throws -> [ProjectFound] {
        let query = [URLQueryItem(name: "path", value: path)]
        return try decode([ProjectFound].self, await http.send(builder.request(.get, "/projects", query: query)))
    }

    public func sessions() async throws -> [SessionInfo] {
        try decode([SessionInfo].self, await http.send(builder.request(.get, "/sessions")))
    }

    public func createSession(_ request: SessionRequest) async throws -> SessionInfo {
        let body = try PreviewJSON.encoder.encode(request)
        return try decode(SessionInfo.self, await http.send(builder.request(.post, "/sessions", body: body)))
    }

    public func session(_ id: String) async throws -> SessionInfo {
        try decode(SessionInfo.self, await http.send(builder.request(.get, "/sessions/\(id)")))
    }

    public func stop(_ id: String) async throws {
        _ = try await http.send(builder.request(.delete, "/sessions/\(id)"))
    }

    public func rebuild(_ id: String) async throws {
        _ = try await http.send(builder.request(.post, "/sessions/\(id)/rebuild"))
    }

    public func relaunch(_ id: String, arguments: [String]?) async throws {
        let body = try JSONEncoder().encode(["arguments": arguments ?? []])
        _ = try await http.send(builder.request(.post, "/sessions/\(id)/launch", body: body))
    }

    public func setAppearance(_ id: String, _ appearance: String) async throws {
        let body = try JSONEncoder().encode(["value": appearance])
        _ = try await http.send(builder.request(.post, "/sessions/\(id)/appearance", body: body))
    }

    public func setContentSize(_ id: String, _ size: String) async throws {
        let body = try JSONEncoder().encode(["value": size])
        _ = try await http.send(builder.request(.post, "/sessions/\(id)/contentsize", body: body))
    }

    /// The newest picture the host holds, as a JPEG, for a card or a thumbnail that does not need
    /// a live stream.
    public func latestFrame(_ id: String) async throws -> Data {
        try await http.send(builder.request(.get, "/sessions/\(id)/frame.jpg"))
    }

    /// Every picture the session draws, as it is drawn, with the session's own events between.
    /// The host sends nothing while the screen is still, so silence is not a fault: heartbeats
    /// arrive every few seconds to tell a still screen from a dead link.
    public func frames(of id: String) -> AsyncThrowingStream<FrameRecord, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try builder.request(.get, "/sessions/\(id)/frames")
                    var decoder = FrameDecoder()
                    for try await chunk in http.byteStream(request) {
                        for record in try decoder.feed(chunk) { continuation.yield(record) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What happens to the session, in order: builds starting and landing, the app closing and
    /// being put back. `since` resumes after the last event a client saw.
    public func events(of id: String, since: Int = 0) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let query = since > 0 ? [URLQueryItem(name: "since", value: String(since))] : []
                    let request = try builder.eventStreamRequest("/sessions/\(id)/events", query: query)
                    for try await raw in http.serverSentEvents(request) {
                        guard !raw.data.isEmpty,
                            let event = try? PreviewJSON.decoder.decode(SessionEvent.self, from: Data(raw.data.utf8))
                        else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try PreviewJSON.decoder.decode(type, from: data)
        } catch {
            throw AgentError.decoding(String(describing: error))
        }
    }
}
