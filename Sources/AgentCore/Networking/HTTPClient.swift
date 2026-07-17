import Foundation
import Logging

#if canImport(FoundationNetworking)
    import EventSource
    import FoundationNetworking
#endif

public struct HTTPClient: Sendable {
    private let session: URLSession
    private let streamSession: URLSession
    private let logger: Logger

    public init(session: URLSession = .shared, logger: Logger = AgentLog.logger("http")) {
        self.session = session
        self.streamSession = Self.makeStreamSession()
        self.logger = logger
    }

    public init(policy: ConnectionPolicy, logger: Logger = AgentLog.logger("http")) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.requestTimeout.timeInterval
        configuration.timeoutIntervalForResource = policy.resourceTimeout.timeInterval
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.httpShouldUsePipelining = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
        self.streamSession = Self.makeStreamSession()
        self.logger = logger
    }

    /// SSE streams idle for long stretches between turns (claude-bridge sends
    /// no keepalives), so the stream session needs generous timeouts — but a
    /// bounded inter-byte timeout is what detects half-open sockets (app
    /// suspension, dead VPN tunnels), so it can't be unlimited: a quiet
    /// stream reconnects every few minutes as the price of noticing death.
    private static func makeStreamSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 86_400 * 7
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
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

    #if canImport(FoundationNetworking)
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
    #else
        public func serverSentEvents(_ request: URLRequest) -> AsyncThrowingStream<SSEvent, Error> {
            let session = streamSession
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        var req = request
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                        req.cachePolicy = .reloadIgnoringLocalCacheData
                        req.timeoutInterval = 3600
                        let (bytes, response) = try await session.bytes(for: req)
                        guard let http = response as? HTTPURLResponse else {
                            throw AgentError.connection("Non-HTTP response")
                        }
                        guard (200..<300).contains(http.statusCode) else {
                            throw AgentError.http(status: http.statusCode, body: "")
                        }
                        var parser = SSEParser()
                        for try await byte in bytes {
                            if let event = parser.consume(byte) {
                                continuation.yield(event)
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch let error as URLError where error.code == .cancelled {
                        continuation.finish()
                    } catch let error as AgentError {
                        continuation.finish(throwing: error)
                    } catch {
                        continuation.finish(throwing: AgentError.connection(String(describing: error)))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    #endif
}
