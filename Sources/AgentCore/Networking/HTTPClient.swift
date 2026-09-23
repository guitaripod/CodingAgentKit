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
    /// Kept so the Linux challengeable path can honour the same deadline the session was built
    /// with — a scan asks for three seconds and must not inherit a stream client's minutes.
    private let policy: ConnectionPolicy

    public init(session: URLSession = .shared, logger: Logger = AgentLog.logger("http")) {
        self.session = session
        self.policy = .default
        #if !canImport(FoundationNetworking)
            self.streamSession = Self.makeStreamSession()
        #endif
        self.logger = logger
    }

    public init(policy: ConnectionPolicy, logger: Logger = AgentLog.logger("http")) {
        self.session = SessionPool.session(for: policy)
        self.policy = policy
        #if !canImport(FoundationNetworking)
            self.streamSession = Self.makeStreamSession()
        #endif
        self.logger = logger
    }

    public func send(_ request: URLRequest) async throws -> Data {
        try await send(request, timeout: policy.requestTimeout)
    }

    /// Sends with a per-request deadline. Some routes answer only when minutes of server work
    /// have finished — opencode's summarize returns no bytes until the whole compaction turn is
    /// done — so the transport's idle budget must not be the one deciding their fate.
    @discardableResult
    public func send(_ request: URLRequest, timeout: Duration) async throws -> Data {
        let (data, http) = try await exchange(request, timeout: timeout)
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// What a conditional read came back with: a body and the validator the server gave it, or
    /// the server's word that the copy already held is still the current one.
    public enum ConditionalReply: Sendable {
        case modified(Data, etag: String?)
        case notModified
    }

    /// A read that carries the validator of the copy already held, so a server that has nothing
    /// new answers in a header instead of in the whole body again. A transcript is re-read on
    /// every open and every reconnect and is megabytes on a long conversation; most of those
    /// re-reads find it exactly as it was.
    ///
    /// A 304 counts only when a validator went out: a server that answers one to an unconditional
    /// request is reporting an error, and it is thrown as one.
    public func sendConditional(_ request: URLRequest, ifNoneMatch etag: String?) async throws
        -> ConditionalReply
    {
        var conditional = request
        if let etag { conditional.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, http) = try await exchange(conditional, timeout: policy.requestTimeout)
        if http.statusCode == 304, etag != nil { return .notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.http(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return .modified(data, etag: http.value(forHTTPHeaderField: "ETag"))
    }

    private func exchange(_ request: URLRequest, timeout: Duration) async throws
        -> (Data, HTTPURLResponse)
    {
        logger.debug("→ \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "?")")
        let data: Data
        let response: URLResponse
        do {
            var req = request
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = timeout.timeInterval
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
        return (data, http)
    }

    #if canImport(FoundationNetworking)
        /// A request whose answer may be a challenge — a probe against a server that has not been
        /// given a password yet, or one whose password is wrong.
        ///
        /// swift-corelibs-foundation's `URLSession` never returns from such a request. A 401
        /// carrying `WWW-Authenticate: Basic` puts its libcurl transport into an authentication
        /// handshake that no disposition escapes: with no delegate it hangs past both timeouts
        /// forever, `.performDefaultHandling` hangs the same way, and rejecting or cancelling the
        /// challenge answers `NSURLErrorCancelled` with no response at all — so the 401 the server
        /// really sent can never be read. Apple's Foundation simply returns it, which is why the
        /// same probe works on the phone and hangs on the desk.
        ///
        /// So on Linux this one path goes through AsyncHTTPClient, which is already here for
        /// streams and has no challenge machinery: it hands back whatever the server said, 401
        /// included, and a password-protected server can be recognised as exactly that.
        public func sendExpectingChallenge(_ request: URLRequest) async throws -> Data {
            logger.debug(
                "→ \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "?") (challengeable)")
            let response: HTTPClientResponse
            do {
                response = try await Self.streamClient.execute(
                    try Self.makeChallengeRequest(from: request),
                    timeout: .nanoseconds(
                        Int64(policy.requestTimeout.timeInterval * 1_000_000_000)))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as HTTPClientError where error == .cancelled {
                throw CancellationError()
            } catch {
                throw AgentError.connection(String(describing: error))
            }
            let status = Int(response.status.code)
            logger.debug("← \(status) \(request.url?.path ?? "")")
            guard (200..<300).contains(status) else {
                throw AgentError.http(status: status, body: await Self.errorBody(response))
            }
            guard let buffer = try? await response.body.collect(upTo: 1 << 20) else { return Data() }
            return Data(buffer.readableBytesView)
        }

        private static func makeChallengeRequest(from request: URLRequest) throws
            -> HTTPClientRequest
        {
            guard let url = request.url?.absoluteString else {
                throw AgentError.connection("Request has no URL")
            }
            var made = HTTPClientRequest(url: url)
            made.method = .init(rawValue: request.httpMethod ?? "GET")
            for (name, value) in request.allHTTPHeaderFields ?? [:] {
                made.headers.replaceOrAdd(name: name, value: value)
            }
            if let body = request.httpBody { made.body = .bytes(body) }
            return made
        }

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
        /// Apple's Foundation returns a 401 as an ordinary response, so a challengeable request is
        /// just a request. Only Linux needs the other road.
        public func sendExpectingChallenge(_ request: URLRequest) async throws -> Data {
            try await send(request)
        }

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

/// One session per set of deadlines for the whole process, because a session is a connection pool.
/// Backends are value types minted freely, one per chat, per health check, per quota read, and a
/// pool per mint paid a fresh TCP handshake for each of them, through a relay when the device is a
/// phone away from home, while the sessions before it stayed alive with sockets nobody would reuse.
/// Streams keep sessions of their own: they hold their connections for hours, and in a pool shared
/// with every short request they would take the slots the reads wait for.
enum SessionPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [ConnectionPolicy: URLSession] = [:]

    static func session(for policy: ConnectionPolicy) -> URLSession {
        lock.withLock {
            if let existing = sessions[policy] { return existing }
            let made = URLSession(configuration: configuration(for: policy))
            sessions[policy] = made
            return made
        }
    }

    /// Eight connections to a host rather than four, because the four used to be per backend and
    /// are now shared by every backend reaching that host: a chat opening fires five reads at once
    /// while the list, the quotas and the health check are still asking theirs.
    private static func configuration(for policy: ConnectionPolicy) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy.requestTimeout.timeInterval
        configuration.timeoutIntervalForResource = policy.resourceTimeout.timeInterval
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        #if !canImport(FoundationNetworking)
            configuration.waitsForConnectivity = true
        #endif
        return configuration
    }
}
