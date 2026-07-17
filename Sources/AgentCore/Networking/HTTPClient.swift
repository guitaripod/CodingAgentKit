import Foundation
import Logging

#if canImport(FoundationNetworking)
    import AsyncHTTPClient
    import FoundationNetworking
    import NIOCore
#endif

public struct HTTPClient: Sendable {
    private let session: URLSession
    #if !canImport(FoundationNetworking)
        private let streamSession: URLSession
    #endif
    private let logger: Logger

    public init(session: URLSession = .shared, logger: Logger = AgentLog.logger("http")) {
        self.session = session
        #if !canImport(FoundationNetworking)
            self.streamSession = Self.makeStreamSession()
        #endif
        self.logger = logger
    }

    public init(policy: ConnectionPolicy, logger: Logger = AgentLog.logger("http")) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.requestTimeout.timeInterval
        configuration.timeoutIntervalForResource = policy.resourceTimeout.timeInterval
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = true
        #endif
        self.session = URLSession(configuration: configuration)
        #if !canImport(FoundationNetworking)
            self.streamSession = Self.makeStreamSession()
        #endif
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
        /// SSE streams idle for long stretches between turns (claude-bridge sends
        /// no keepalives), so the stream transport needs generous timeouts — but a
        /// bounded inter-byte timeout is what detects half-open sockets (app
        /// suspension, dead VPN tunnels), so it can't be unlimited: a quiet
        /// stream reconnects every few minutes as the price of noticing death.
        /// Both platforms use a 300s inter-byte / 7-day total budget and surface
        /// every stream death to the consumer, whose reconnect logic repairs any
        /// gap; nothing reconnects silently underneath it.
        public func serverSentEvents(_ request: URLRequest) -> AsyncThrowingStream<SSEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let streamRequest = try Self.makeStreamRequest(from: request)
                        let response = try await Self.streamClient.execute(
                            streamRequest, timeout: .hours(24 * 7))
                        guard (200..<300).contains(response.status.code) else {
                            throw AgentError.http(
                                status: Int(response.status.code),
                                body: await Self.errorBody(response))
                        }
                        var parser = SSEParser()
                        for try await buffer in response.body {
                            for byte in buffer.readableBytesView {
                                if let event = parser.consume(byte) {
                                    continuation.yield(event)
                                }
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch let error as HTTPClientError where error == .cancelled {
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

        private static let streamClient: AsyncHTTPClient.HTTPClient = {
            var configuration = AsyncHTTPClient.HTTPClient.Configuration()
            configuration.timeout = .init(connect: .seconds(15), read: .seconds(300))
            return AsyncHTTPClient.HTTPClient(
                eventLoopGroupProvider: .singleton, configuration: configuration)
        }()

        private static func makeStreamRequest(from request: URLRequest) throws -> HTTPClientRequest {
            guard let url = request.url?.absoluteString else {
                throw AgentError.connection("Stream request has no URL")
            }
            var streamRequest = HTTPClientRequest(url: url)
            streamRequest.method = .init(rawValue: request.httpMethod ?? "GET")
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                streamRequest.headers.replaceOrAdd(name: name, value: value)
            }
            streamRequest.headers.replaceOrAdd(name: "Accept", value: "text/event-stream")
            streamRequest.headers.replaceOrAdd(name: "Cache-Control", value: "no-cache")
            if let body = request.httpBody {
                streamRequest.body = .bytes(body)
            }
            return streamRequest
        }

        private static func errorBody(_ response: HTTPClientResponse) async -> String {
            guard let buffer = try? await response.body.collect(upTo: 65_536) else { return "" }
            return String(buffer: buffer)
        }
    #else
        /// SSE streams idle for long stretches between turns (claude-bridge sends
        /// no keepalives), so the stream transport needs generous timeouts — but a
        /// bounded inter-byte timeout is what detects half-open sockets (app
        /// suspension, dead VPN tunnels), so it can't be unlimited: a quiet
        /// stream reconnects every few minutes as the price of noticing death.
        /// Both platforms use a 300s inter-byte / 7-day total budget and surface
        /// every stream death to the consumer, whose reconnect logic repairs any
        /// gap; nothing reconnects silently underneath it.
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
                            throw AgentError.http(
                                status: http.statusCode, body: await Self.errorBody(bytes))
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

        private static func makeStreamSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 300
            configuration.timeoutIntervalForResource = 86_400 * 7
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.waitsForConnectivity = true
            return URLSession(configuration: configuration)
        }

        private static func errorBody(_ bytes: URLSession.AsyncBytes) async -> String {
            var data = Data()
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= 65_536 { break }
                }
            } catch {
                return String(data: data, encoding: .utf8) ?? ""
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
    #endif
}
