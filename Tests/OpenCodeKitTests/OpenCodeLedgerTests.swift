import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct OpenCodeLedgerTests {
    private static let now = Date(timeIntervalSince1970: 1_788_264_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private func milliseconds(daysAgo: Double) -> Double {
        (Self.now.timeIntervalSince1970 - daysAgo * 86400) * 1000
    }

    private func sessions(_ json: String) throws -> [OCSession] {
        try JSONDecoder().decode([OCSession].self, from: Data(json.utf8))
    }

    private func session(
        id: String, cost: Double, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        cacheWrite: Int = 0, model: String = "grok-4.6", provider: String = "xai",
        directory: String = "/home/marcus/Dev/iOS/Tailscode", daysAgo: Double,
        parent: String? = nil, title: String = "A conversation"
    ) throws -> OCSession {
        let parentLine = parent.map { "\"parentID\":\"\($0)\"," } ?? ""
        return try sessions(
            """
            [{"id":"\(id)",\(parentLine)"title":"\(title)","directory":"\(directory)",
              "agent":"build","cost":\(cost),
              "tokens":{"input":\(input),"output":\(output),"reasoning":0,
                        "cache":{"read":\(cacheRead),"write":\(cacheWrite)}},
              "model":{"id":"\(model)","providerID":"\(provider)","variant":"low"},
              "time":{"created":\(milliseconds(daysAgo: daysAgo)),
                      "updated":\(milliseconds(daysAgo: daysAgo))}}]
            """)[0]
    }

    /// The exact record shape a live `GET /session` on opencode 1.18 returns, including the
    /// running totals the whole ledger is built from.
    @Test func liveRecordShapeCarriesTheRunningTotals() throws {
        let decoded = try sessions(
            """
            [{"id":"ses_fa605c3e5ffeOASOKEHcmj17ny","slug":"silent-tiger","projectID":"global",
              "directory":"/home/marcus","path":"home/marcus",
              "summary":{"additions":0,"deletions":0,"files":0},"cost":0.422398,
              "tokens":{"input":113796,"output":698,"reasoning":1167,
                        "cache":{"read":367232,"write":0}},
              "title":"Nearby farmer's markets","agent":"build",
              "model":{"id":"grok-4.6","providerID":"xai","variant":"low"},"version":"1.18.22",
              "time":{"created":1788215966746,"updated":1788216075520}}]
            """)
        #expect(decoded[0].cost == 0.422398)
        #expect(decoded[0].tokens?.cache?.read == 367232)
        #expect(decoded[0].agent == "build")
    }

    @Test func aggregatesMoneyTokensModelsAndProjects() throws {
        let report = OpenCodeLedger.report(
            sessions: [
                try session(
                    id: "a", cost: 1.5, input: 1000, output: 500, cacheRead: 4000, daysAgo: 1),
                try session(
                    id: "b", cost: 0.5, input: 200, output: 100, daysAgo: 1,
                    title: "Second chat"),
                try session(
                    id: "c", cost: 2, input: 300, output: 900, cacheWrite: 8000,
                    model: "claude-opus-5", provider: "anthropic",
                    directory: "/home/marcus/Dev/other", daysAgo: 3, title: "Third chat"),
            ], days: 30, now: Self.now, calendar: calendar)

        #expect(report.totals.costUSD == 4)
        #expect(report.totals.sessions == 3)
        #expect(report.totals.tokens.input == 1500)
        #expect(report.totals.tokens.output == 1500)
        #expect(report.totals.tokens.cacheRead == 4000)
        #expect(report.totals.tokens.cacheWrite == 8000)
        #expect(report.totals.activeDays == 2)
        #expect(report.daily.count == 2)
        #expect(report.models.map(\.model) == ["anthropic/claude-opus-5", "xai/grok-4.6"])
        #expect(report.models.first?.costUSD == 2)
        #expect(report.projects.map(\.name) == ["other", "Tailscode"])
        #expect(report.projects.first?.sessions == 1)
        #expect(report.projects.last?.sessions == 2)
        #expect(report.records.priciestSession?.title == "Third chat")
    }

    /// Reasoning bills as output, and opencode's single cache write is the five-minute tier.
    @Test func reasoningJoinsOutputAndCacheWriteTakesTheShortTier() throws {
        let decoded = try sessions(
            """
            [{"id":"a","title":"t","directory":"/tmp","cost":1,
              "tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":7,"write":9}},
              "model":{"id":"m","providerID":"p"},
              "time":{"created":\(milliseconds(daysAgo: 1)),
                      "updated":\(milliseconds(daysAgo: 1))}}]
            """)
        let report = OpenCodeLedger.report(
            sessions: decoded, days: 30, now: Self.now, calendar: calendar)
        #expect(report.totals.tokens.output == 25)
        #expect(report.totals.tokens.cacheWrite5m == 9)
        #expect(report.totals.tokens.cacheWrite1h == 0)
    }

    /// A model that costs nothing to run did the work anyway. It must be counted, and it must
    /// not sort below a hosted model that spent a cent on fifteen tokens.
    @Test func aFreeLocalModelIsCountedAndOutranksACheapHostedOne() throws {
        let report = OpenCodeLedger.report(
            sessions: [
                try session(
                    id: "local", cost: 0, input: 900_000, output: 40000,
                    model: "qwen38-nvfp4:latest", provider: "ollama", daysAgo: 1),
                try session(id: "cloud", cost: 0.004, input: 10, output: 5, daysAgo: 1),
            ], days: 30, now: Self.now, calendar: calendar)

        #expect(report.isEmpty == false)
        #expect(report.totals.sessions == 2)
        #expect(report.models.map(\.model) == ["ollama/qwen38-nvfp4:latest", "xai/grok-4.6"])
        #expect(report.models.first?.costUSD == 0)
        #expect(report.models.first?.tokens.total == 940_000)
    }

    /// An account that only ever runs local models has a full ledger and no money at all.
    @Test func aFreeOnlyAccountIsNotAnEmptyReport() throws {
        let report = OpenCodeLedger.report(
            sessions: [
                try session(
                    id: "local", cost: 0, input: 5000, output: 900, model: "gpt-oss:120b",
                    provider: "ollama", daysAgo: 2)
            ], days: 30, now: Self.now, calendar: calendar)
        #expect(report.isEmpty == false)
        #expect(report.totals.costUSD == 0)
        #expect(report.totals.tokens.total == 5900)
    }

    @Test func leavesOutSessionsOutsideTheWindowAndOnesNobodyPrompted() throws {
        let report = OpenCodeLedger.report(
            sessions: [
                try session(id: "old", cost: 9, input: 100, daysAgo: 45),
                try session(id: "empty", cost: 0, daysAgo: 1),
                try session(id: "kept", cost: 1, input: 10, daysAgo: 2),
            ], days: 30, now: Self.now, calendar: calendar)
        #expect(report.totals.costUSD == 1)
        #expect(report.totals.sessions == 1)
        #expect(report.daily.count == 1)
    }

    /// A fan-out is work, not conversations: its money counts, its runs count, and it does not
    /// inflate the number of chats the window holds.
    @Test func childSessionsCountAsSubagentRunsRatherThanConversations() throws {
        let report = OpenCodeLedger.report(
            sessions: [
                try session(id: "parent", cost: 1, input: 100, daysAgo: 1),
                try session(id: "kid1", cost: 0.5, input: 50, daysAgo: 1, parent: "parent"),
                try session(id: "kid2", cost: 0.25, input: 20, daysAgo: 1, parent: "parent"),
            ], days: 30, now: Self.now, calendar: calendar)
        #expect(report.totals.costUSD == 1.75)
        #expect(report.totals.sessions == 1)
        #expect(report.subagents.runs == 2)
        #expect(report.subagents.costUSD == 0.75)
        #expect(report.records.priciestSession?.id == "parent")
        #expect(report.projects.first?.sessions == 1)
    }

    @Test func declaresWhatSessionRecordsCannotKnow() throws {
        let report = OpenCodeLedger.report(
            sessions: [try session(id: "a", cost: 1, input: 10, daysAgo: 1)], days: 30,
            now: Self.now, calendar: calendar)
        #expect(report.covers == .sessionTotals)
        #expect(report.covers.contains(.turns) == false)
        #expect(report.covers.contains(.clock) == false)
        #expect(report.totals.turns == 0)
        #expect(report.tools.isEmpty)
        #expect(report.hourTurns.isEmpty)
    }

    /// A report from a server that predates the distinction measured everything, and its silence
    /// must not read as a server that measured nothing.
    @Test func aReportWithoutACoverageKeyCoversEverything() throws {
        let json = """
            {"since":0,"generatedAt":0,"days":30,"estimated":true,
             "totals":{"costUSD":1,"tokens":{"input":1,"output":1,"cacheRead":0,
                       "cacheWrite5m":0,"cacheWrite1h":0},"turns":4,"toolCalls":2,
                       "sessions":1,"activeDays":1},
             "daily":[],"models":[],"projects":[],"tools":[],"hourTurns":[],"hourCostUSD":[],
             "cacheSavedUSD":0,"compactions":{"count":0,"reclaimedTokens":0},
             "subagents":{"runs":0,"tokens":{"input":0,"output":0,"cacheRead":0,
                          "cacheWrite5m":0,"cacheWrite1h":0},"costUSD":0},
             "records":{"streakDays":0}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let report = try decoder.decode(UsageAnalyticsReport.self, from: Data(json.utf8))
        #expect(report.coverage == nil)
        #expect(report.covers == .all)
    }

    @Test func coverageSurvivesARoundTrip() throws {
        let report = UsageAnalyticsReport(
            since: Self.now, generatedAt: Self.now, days: 30, coverage: .sessionTotals)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let restored = try decoder.decode(
            UsageAnalyticsReport.self, from: try encoder.encode(report))
        #expect(restored.coverage == .sessionTotals)
        #expect(restored.covers == .sessionTotals)
    }
}
