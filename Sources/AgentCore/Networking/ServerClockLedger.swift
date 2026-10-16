import Foundation

/// How far a server's clock is from this device's, as last measured.
public struct ServerClockReading: Sendable, Equatable {
    /// The server's clock minus this device's clock; positive when the server runs ahead.
    public let skew: TimeInterval
    public let samples: Int
    public let measuredAt: Date

    public init(skew: TimeInterval, samples: Int, measuredAt: Date) {
        self.skew = skew
        self.samples = samples
        self.measuredAt = measuredAt
    }
}

/// Learns each server's clock offset from the `Date` header of responses the client already
/// receives, so no extra request is ever made to measure it.
public final class ServerClockLedger: @unchecked Sendable {
    public static let shared = ServerClockLedger()

    static let capacity = 8
    static let maxRoundTrip: TimeInterval = 5
    static let maxAge: TimeInterval = 600

    private struct Sample {
        let skew: TimeInterval
        let receivedAt: Date
    }

    private let lock = NSLock()
    private var samples: [String: [Sample]] = [:]

    private static let formatLock = NSLock()
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    public init() {}

    /// The `Date` header names the second the server sent its reply and drops the fraction, so
    /// half a second is added back, and the device's side of the reply is the middle of the
    /// round trip.
    public func record(url: URL, serverDate: Date, sentAt: Date, receivedAt: Date) {
        let roundTrip = receivedAt.timeIntervalSince(sentAt)
        guard roundTrip >= 0, roundTrip <= Self.maxRoundTrip else { return }
        let key = Self.key(for: url)
        guard !key.isEmpty else { return }
        let deviceTime = sentAt.addingTimeInterval(roundTrip / 2)
        let skew = serverDate.addingTimeInterval(0.5).timeIntervalSince(deviceTime)
        lock.withLock {
            var held = samples[key] ?? []
            held.append(Sample(skew: skew, receivedAt: receivedAt))
            if held.count > Self.capacity { held.removeFirst(held.count - Self.capacity) }
            samples[key] = held
        }
    }

    public func reading(for url: URL, now: Date = Date()) -> ServerClockReading? {
        let key = Self.key(for: url)
        let fresh = lock.withLock {
            (samples[key] ?? []).filter { now.timeIntervalSince($0.receivedAt) <= Self.maxAge }
        }
        guard let newest = fresh.map(\.receivedAt).max() else { return nil }
        let sorted = fresh.map(\.skew).sorted()
        let middle = sorted.count / 2
        let median =
            sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
        return ServerClockReading(skew: median, samples: fresh.count, measuredAt: newest)
    }

    public static func key(for url: URL) -> String {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return "" }
        let scheme = url.scheme?.lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        guard let port else { return host }
        return "\(host):\(port)"
    }

    public static func parseHTTPDate(_ header: String) -> Date? {
        formatLock.withLock { formatter.date(from: header) }
    }
}
