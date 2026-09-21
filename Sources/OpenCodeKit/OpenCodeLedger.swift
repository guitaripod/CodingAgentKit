import AgentCore
import Foundation

/// The account's ledger as opencode can afford to serve it.
///
/// opencode keeps a running total on every session record — what the conversation cost, the
/// tokens it burned by tier, the model that spent them, the directory it ran in — so a whole
/// window adds up from one listing. The messages inside would say the same thing turn by turn and
/// cost a hundred times the bytes to ask for (one long conversation is thirteen megabytes of tool
/// output, and a month of them is gigabytes), which is not a request to make of a phone on a
/// cellular link. So the report is built from the records, and declares in
/// ``UsageAnalyticsReport/Coverage`` exactly what records cannot know: how many turns are inside a
/// conversation, which tools those turns called, the hour each one began, and which day of a
/// conversation that spanned two the money was actually spent on.
enum OpenCodeLedger {
    /// What to ask the listing for. A month of heavy use runs to a couple of hundred
    /// conversations; this is a guard against a pathological store, not a window.
    static let sessionCeiling = 2000

    struct Tokens: Sendable {
        var input = 0
        var output = 0
        var reasoning = 0
        var cacheRead = 0
        var cacheWrite = 0
    }

    /// What a session record says that a ledger can count, the same on both generations of the
    /// wire: the conversation's running cost and tokens, the model that spent them, where it
    /// ran, when it was last worked on, and whether it was a spawned agent's.
    struct Record: Sendable {
        var id: String
        var title: String?
        var parentID: String?
        var directory: String?
        var lastActive: Date?
        var cost: Double?
        var tokens: Tokens
        var modelID: String?
        var providerID: String?
    }

    static func report(
        sessions: [OCSession], days: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> UsageAnalyticsReport {
        report(records: sessions.map(Record.init), days: days, now: now, calendar: calendar)
    }

    /// Aggregate the records into the account's report. Sessions outside the window, and sessions
    /// nobody ever prompted, are left out — an empty conversation is not a day's work.
    static func report(
        records: [Record], days: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> UsageAnalyticsReport {
        let since =
            calendar.startOfDay(
                for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let formatter = dayFormatter(calendar)

        var totals = UsageAnalyticsReport.Totals()
        var tokensTotal = SessionSpendReport.Tokens()
        var daily: [String: UsageAnalyticsReport.Day] = [:]
        var models: [String: SessionSpendReport.ModelShare] = [:]
        var projects: [String: UsageAnalyticsReport.Project] = [:]
        var subagents = UsageAnalyticsReport.Subagents()
        var priciest: UsageAnalyticsReport.Records.Session?

        for session in records {
            guard let at = session.lastActive, at >= since else { continue }
            let tokens = tokens(of: session.tokens)
            let cost = max(0, session.cost ?? 0)
            guard tokens.total > 0 || cost > 0 else { continue }
            let isChild = session.parentID?.isEmpty == false

            totals.costUSD += cost
            tokensTotal = add(tokensTotal, tokens)
            if !isChild { totals.sessions += 1 }

            let key = formatter.string(from: at)
            var day =
                daily[key] ?? UsageAnalyticsReport.Day(day: key)
            day.costUSD += cost
            day.tokens = add(day.tokens, tokens)
            if !isChild { day.sessions += 1 }
            daily[key] = day

            if let name = modelKey(session) {
                var row =
                    models[name]
                    ?? SessionSpendReport.ModelShare(
                        model: name, turns: 0, tokens: SessionSpendReport.Tokens(), costUSD: 0)
                row.tokens = add(row.tokens, tokens)
                row.costUSD += cost
                models[name] = row
            }

            if let directory = session.directory, !directory.isEmpty {
                var row =
                    projects[directory]
                    ?? UsageAnalyticsReport.Project(
                        directory: directory, name: projectName(directory))
                if !isChild { row.sessions += 1 }
                row.costUSD += cost
                row.tokens = add(row.tokens, tokens)
                projects[directory] = row
            }

            if isChild {
                subagents.runs += 1
                subagents.costUSD += cost
                subagents.tokens = add(subagents.tokens, tokens)
            } else if cost > 0, cost > (priciest?.costUSD ?? 0) {
                priciest = UsageAnalyticsReport.Records.Session(
                    id: session.id, title: title(session), costUSD: cost, turns: 0)
            }
        }

        totals.tokens = tokensTotal
        totals.activeDays = daily.count

        return UsageAnalyticsReport(
            since: since, generatedAt: now, days: days, estimated: true, totals: totals,
            daily: daily.values.sorted { $0.day < $1.day },
            models: models.values.sorted(by: byWork),
            projects: projects.values.sorted(by: byMoney),
            tools: [], hourTurns: [], hourCostUSD: [], cacheSavedUSD: 0,
            compactions: UsageAnalyticsReport.Compactions(), subagents: subagents,
            records: UsageAnalyticsReport.Records(priciestSession: priciest),
            coverage: .sessionTotals)
    }

    /// Which model did the most work, which is a token count rather than a bill: a model running
    /// on the server's own GPU costs nothing and can still have done most of the month, and
    /// sorting on money would put it under a hosted call worth a cent. Ties break on money and
    /// then on name so a listing never reorders itself between two reads.
    private static func byWork(
        _ lhs: SessionSpendReport.ModelShare, _ rhs: SessionSpendReport.ModelShare
    ) -> Bool {
        if lhs.tokens.fresh != rhs.tokens.fresh { return lhs.tokens.fresh > rhs.tokens.fresh }
        if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
        return lhs.model < rhs.model
    }

    /// A project is ranked by what it cost, which is the question asked of a directory, with the
    /// same stable tiebreak for the free ones.
    private static func byMoney(
        _ lhs: UsageAnalyticsReport.Project, _ rhs: UsageAnalyticsReport.Project
    ) -> Bool {
        if lhs.costUSD != rhs.costUSD { return lhs.costUSD > rhs.costUSD }
        if lhs.tokens.fresh != rhs.tokens.fresh { return lhs.tokens.fresh > rhs.tokens.fresh }
        return lhs.name < rhs.name
    }

    /// Reasoning is billed as output and read as output everywhere else in the app, and opencode
    /// reports one cache write without a time-to-live, which is the five-minute tier's price.
    private static func tokens(of tokens: Tokens) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: tokens.input,
            output: tokens.output + tokens.reasoning,
            cacheRead: tokens.cacheRead,
            cacheWrite5m: tokens.cacheWrite)
    }

    /// `provider/model`, so a reader downstream can tell an Ollama model on the server's own GPU
    /// from a hosted one with the same name.
    private static func modelKey(_ record: Record) -> String? {
        guard let id = record.modelID, !id.isEmpty else { return nil }
        guard let provider = record.providerID, !provider.isEmpty else { return id }
        return "\(provider)/\(id)"
    }

    private static func projectName(_ directory: String) -> String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private static func title(_ session: Record) -> String {
        let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? session.id : title
    }

    private static func add(
        _ lhs: SessionSpendReport.Tokens, _ rhs: SessionSpendReport.Tokens
    ) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite5m: lhs.cacheWrite5m + rhs.cacheWrite5m,
            cacheWrite1h: lhs.cacheWrite1h + rhs.cacheWrite1h)
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

extension OpenCodeLedger.Record {
    init(_ session: OCSession) {
        self.init(
            id: session.id,
            title: session.title,
            parentID: session.parentID,
            directory: session.directory,
            lastActive: (session.time?.updated ?? session.time?.created).map {
                Date(timeIntervalSince1970: $0 / 1000)
            },
            cost: session.cost,
            tokens: OpenCodeLedger.Tokens(
                input: Int(session.tokens?.input ?? 0),
                output: Int(session.tokens?.output ?? 0),
                reasoning: Int(session.tokens?.reasoning ?? 0),
                cacheRead: Int(session.tokens?.cache?.read ?? 0),
                cacheWrite: Int(session.tokens?.cache?.write ?? 0)),
            modelID: session.model?.id,
            providerID: session.model?.providerID)
    }
}
