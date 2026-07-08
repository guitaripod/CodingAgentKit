import EventSource
import Foundation
import Logging

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct HTTPClient: Sendable {
    private let session: URLSession
    private let logger: Logger

    public init(session: URLSession = .shared, logger: Logger = AgentLog.logger("http")) {
        self.session = session
        self.logger = logger
    }

    public init(policy: ConnectionPolicy, logger: Logger = AgentLog.logger("http")) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.requestTimeout.timeInterval
        configuration.timeoutIntervalForResource = policy.resourceTimeout.timeInterval
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldUsePipelining = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
        self.logger = logger
    }

    @discardableResult
    public func send(_ request: URLRequest) async throws -> Data {
        logger.debug("→ \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "?")")
        let data: Data
        let response: URLResponse
        do {
            var req = request
            req.cachePolicy = .reloadIgnoringLocalCacheData
            (data, response) = try await session.data(for: req)
        } catch {
            throw AgentError.connection(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.connection("Non-HTTP response")
        }
        logger.debug("← \(http.statusCode) \(request.url?.path ?? "")")
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    public func serverSentEvents(_ request: URLRequest) -> AsyncThrowingStream<SSEvent, Error> {
        AsyncThrowingStream { continuation in
            let source = EventSource(request: request)
            source.onMessage = { event in
                continuation.yield(SSEvent(id: event.id, type: event.event, data: event.data))
            }
            source.onError = { error in
                guard let error else {
                    continuation.finish()
                    return
                }
                if error is EventSourceError {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish(throwing: AgentError.connection(String(describing: error)))
                }
            }
            continuation.onTermination = { _ in
                Task { await source.close() }
            }
        }
    }
}
