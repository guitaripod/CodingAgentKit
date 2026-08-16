import Foundation

/// Timeouts and reconnection tuning for a backend connection.
public struct ConnectionPolicy: Sendable, Hashable {
    public var requestTimeout: Duration
    public var resourceTimeout: Duration
    public var reconnectBaseDelay: Duration
    public var reconnectMaxDelay: Duration
    public var reconnectJitter: Double
    public var maxReconnectAttempts: Int?
    /// How often an open conversation consults the server's own record of the session
    /// (``CodingAgentBackend/revision(for:)``), and how long the stream must have been silent
    /// before it bothers: a conversation whose events are arriving never asks at all.
    public var sessionRecordInterval: Duration

    public init(
        requestTimeout: Duration = .seconds(30),
        resourceTimeout: Duration = .seconds(120),
        reconnectBaseDelay: Duration = .seconds(1),
        reconnectMaxDelay: Duration = .seconds(30),
        reconnectJitter: Double = 0.2,
        maxReconnectAttempts: Int? = nil,
        sessionRecordInterval: Duration = .seconds(10)
    ) {
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectMaxDelay = reconnectMaxDelay
        self.reconnectJitter = reconnectJitter
        self.maxReconnectAttempts = maxReconnectAttempts
        self.sessionRecordInterval = sessionRecordInterval
    }

    public static let `default` = ConnectionPolicy()

    /// Backoff delay for a given zero-based attempt: capped exponential with proportional jitter.
    public func backoffDelay(attempt: Int, jitterFraction: Double) -> Duration {
        let exponent = min(attempt, 16)
        let base = reconnectBaseDelay.timeInterval * pow(2.0, Double(exponent))
        let capped = min(base, reconnectMaxDelay.timeInterval)
        let jitter = capped * reconnectJitter * max(0, min(1, jitterFraction))
        return .seconds(capped + jitter)
    }
}

extension Duration {
    public var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
