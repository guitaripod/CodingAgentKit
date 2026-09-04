import AgentCore
import Foundation

/// The delegate daemon on one machine: packets in, verified patches out, every step on a stream.
public struct DelegateClient: Sendable {
    public static let defaultPort = 4100
    public static let username = "delegate"

    private let builder: RequestBuilder
    private let http: HTTPClient

    public init(config: ServerConfig) {
        builder = RequestBuilder(config: config)
        http = HTTPClient(policy: config.policy, logger: AgentLog.logger("delegate"))
    }

    /// A config for the daemon beside the coding-agent server at `host`, on the daemon's own port.
    public static func config(host: String, port: Int = defaultPort, password: String?, policy: ConnectionPolicy = .default) -> ServerConfig? {
        guard let url = URL(string: "http://\(host):\(port)") else { return nil }
        let credentials = password.map { BasicCredentials(username: username, password: $0) }
        return ServerConfig(baseURL: url, credentials: credentials, policy: policy)
    }

    public func health() async throws -> DelegateHealth {
        try decode(DelegateHealth.self, await http.send(builder.request(.get, "/health")))
    }

    public func capabilities() async throws -> DelegateCapabilities {
        try decode(DelegateCapabilities.self, await http.send(builder.request(.get, "/v1/capabilities")))
    }

    public func tiers() async throws -> [DelegateTier] {
        try decode([DelegateTier].self, await http.send(builder.request(.get, "/v1/tiers")))
    }

    public func runs(limit: Int = 50) async throws -> [DelegateRun] {
        let query = [URLQueryItem(name: "limit", value: String(limit))]
        return try decode([DelegateRun].self, await http.send(builder.request(.get, "/v1/runs", query: query)))
    }

    public func run(id: String) async throws -> DelegateRunDetail {
        try decode(DelegateRunDetail.self, await http.send(builder.request(.get, "/v1/runs/\(id)")))
    }

    public func stats(taskClass: String? = nil) async throws -> [DelegateStat] {
        let query = taskClass.map { [URLQueryItem(name: "class", value: $0)] } ?? []
        return try decode([DelegateStat].self, await http.send(builder.request(.get, "/v1/stats", query: query)))
    }

    /// Starts a run and answers its id; the run itself is followed with `events(runID:)`.
    public func start(packet: DelegatePacket, overrides: DelegateOverrides = DelegateOverrides()) async throws -> String {
        let body = try JSONCoding.encoder.encode(StartBody(packet: packet, overrides: overrides))
        let data = try await http.send(builder.request(.post, "/v1/runs", body: body))
        return try decode(Started.self, data).runID
    }

    public func replay(runID: String, overrides: DelegateOverrides = DelegateOverrides()) async throws -> String {
        let body = try JSONCoding.encoder.encode(overrides)
        let data = try await http.send(builder.request(.post, "/v1/runs/\(runID)/replay", body: body))
        return try decode(Started.self, data).runID
    }

    public func approve(runID: String, approved: Bool) async throws {
        let body = try JSONCoding.encoder.encode(["approved": approved])
        _ = try await http.send(builder.request(.post, "/v1/runs/\(runID)/approve", body: body))
    }

    public func cancel(runID: String) async throws {
        _ = try await http.send(builder.request(.post, "/v1/runs/\(runID)/cancel"))
    }

    /// Every event of the run from `after` onward — the stored past first, then live — ending with `run_finished`.
    public func events(runID: String, after seq: Int = 0) -> AsyncThrowingStream<DelegateEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let query = seq > 0 ? [URLQueryItem(name: "after", value: String(seq))] : []
                    let request = try builder.eventStreamRequest("/v1/runs/\(runID)/events", query: query)
                    for try await raw in http.serverSentEvents(request) {
                        guard let envelope = Self.parseEnvelope(raw) else { continue }
                        continuation.yield(envelope)
                        if envelope.event.isTerminal { break }
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

    /// Lines the daemon puts on the wire that are not run events (keep-alives, comments) are dropped.
    public static func parseEnvelope(_ raw: SSEvent) -> DelegateEnvelope? {
        guard !raw.data.isEmpty else { return nil }
        return try? JSONCoding.decoder.decode(DelegateEnvelope.self, from: Data(raw.data.utf8))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(type, from: data)
        } catch {
            throw AgentError.decoding(String(describing: error))
        }
    }

    private struct StartBody: Encodable {
        var packet: DelegatePacket
        var overrides: DelegateOverrides

        enum CodingKeys: String, CodingKey { case packet, tier, ceiling, mode, attempts }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(packet, forKey: .packet)
            try c.encodeIfPresent(overrides.tier, forKey: .tier)
            try c.encodeIfPresent(overrides.ceiling, forKey: .ceiling)
            try c.encodeIfPresent(overrides.mode, forKey: .mode)
            try c.encodeIfPresent(overrides.attempts, forKey: .attempts)
        }
    }

    private struct Started: Decodable {
        var runID: String
        enum CodingKeys: String, CodingKey { case runID = "run_id" }
    }
}
