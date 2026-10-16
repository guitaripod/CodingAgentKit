import Foundation
import Testing

@testable import AgentCore

@Suite struct ServerClockLedgerTests {
    private let url = URL(string: "http://arch:4098/sessions")!
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(
        _ ledger: ServerClockLedger, skew: TimeInterval, at offset: TimeInterval = 0,
        roundTrip: TimeInterval = 0.2
    ) {
        let sentAt = base.addingTimeInterval(offset)
        let receivedAt = sentAt.addingTimeInterval(roundTrip)
        let deviceTime = sentAt.addingTimeInterval(roundTrip / 2)
        let serverDate = deviceTime.addingTimeInterval(skew - 0.5)
        ledger.record(url: url, serverDate: serverDate, sentAt: sentAt, receivedAt: receivedAt)
    }

    @Test func parsesRFC1123Date() throws {
        let date = try #require(
            ServerClockLedger.parseHTTPDate("Fri, 16 Oct 2026 17:51:05 GMT"))
        #expect(date.timeIntervalSince1970 == 1_792_173_065)
        #expect(ServerClockLedger.parseHTTPDate("not a date") == nil)
    }

    @Test func keyFillsDefaultPortsAndLowercases() {
        let http = ServerClockLedger.key(for: URL(string: "http://Arch/x")!)
        let https = ServerClockLedger.key(for: URL(string: "https://ARCH/x")!)
        #expect(http == "arch:80")
        #expect(https == "arch:443")
        #expect(
            ServerClockLedger.key(for: URL(string: "http://arch:4098/x")!)
                == ServerClockLedger.key(for: URL(string: "http://ARCH:4098/y")!))
        #expect(ServerClockLedger.key(for: URL(string: "http://arch:4098/x")!) == "arch:4098")
        #expect(ServerClockLedger.key(for: URL(string: "file:///tmp/x")!) == "")
    }

    @Test func serverAheadGivesPositiveSkew() throws {
        let ledger = ServerClockLedger()
        record(ledger, skew: 42)
        let reading = try #require(ledger.reading(for: url, now: base.addingTimeInterval(1)))
        #expect(abs(reading.skew - 42) < 0.001)
        #expect(reading.samples == 1)
    }

    @Test func serverBehindGivesNegativeSkew() throws {
        let ledger = ServerClockLedger()
        record(ledger, skew: -30)
        let reading = try #require(ledger.reading(for: url, now: base.addingTimeInterval(1)))
        #expect(abs(reading.skew + 30) < 0.001)
    }

    @Test func reportsMedianIgnoringOutlier() throws {
        let ledger = ServerClockLedger()
        for (index, skew) in [10.0, 10.2, 9.8, 300, 10.1].enumerated() {
            record(ledger, skew: skew, at: Double(index))
        }
        let reading = try #require(ledger.reading(for: url, now: base.addingTimeInterval(10)))
        #expect(abs(reading.skew - 10.1) < 0.001)
        #expect(reading.samples == 5)
        #expect(reading.measuredAt == base.addingTimeInterval(4.2))
    }

    @Test func keepsOnlyTheLastEightSamples() throws {
        let ledger = ServerClockLedger()
        for index in 0..<12 { record(ledger, skew: Double(index), at: Double(index)) }
        let reading = try #require(ledger.reading(for: url, now: base.addingTimeInterval(20)))
        #expect(reading.samples == 8)
    }

    @Test func dropsStaleSamples() throws {
        let ledger = ServerClockLedger()
        record(ledger, skew: 5, at: 0)
        record(ledger, skew: 7, at: 500)
        let both = try #require(ledger.reading(for: url, now: base.addingTimeInterval(550)))
        #expect(both.samples == 2)
        let onlyNewer = try #require(ledger.reading(for: url, now: base.addingTimeInterval(700)))
        #expect(onlyNewer.samples == 1)
        #expect(abs(onlyNewer.skew - 7) < 0.001)
        #expect(ledger.reading(for: url, now: base.addingTimeInterval(2000)) == nil)
    }

    @Test func rejectsSlowAndNegativeRoundTrips() {
        let ledger = ServerClockLedger()
        record(ledger, skew: 3, roundTrip: 6)
        record(ledger, skew: 3, roundTrip: -1)
        #expect(ledger.reading(for: url, now: base.addingTimeInterval(10)) == nil)
    }

    @Test func unknownServerHasNoReading() {
        let ledger = ServerClockLedger()
        record(ledger, skew: 1)
        let other = URL(string: "http://mini:4098/x")!
        #expect(ledger.reading(for: other, now: base.addingTimeInterval(1)) == nil)
    }
}
