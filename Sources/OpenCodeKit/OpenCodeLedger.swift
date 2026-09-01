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

    /// Aggregate the records into the account's report. Sessions outside the window, and sessions
    /// nobody ever prompted, are left out — an empty conversation is not a day's work.
    static func report(
        sessions: [OCSession], days: Int, now: Date = Date(), calendar: Calendar = .current
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

        for session in sessions {
            guard let at = lastActive(session), at >= since else { continue }
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

            if let name = modelKey(session.model) {
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

    /// The record's own clock: when the conversation was last worked on, which is the day its
    /// running total belongs to. A conversation that spanned midnight lands on the later day —
    /// the imprecision ``UsageAnalyticsReport/Coverage/dailyPrecision`` exists to declare.
    private static func lastActive(_ session: OCSession) -> Date? {
        guard let milliseconds = session.time?.updated ?? session.time?.created else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Reasoning is billed as output and read as output everywhere else in the app, and opencode
    /// reports one cache write without a time-to-live, which is the five-minute tier's price.
    private static func tokens(of tokens: OCTokens?) -> SessionSpendReport.Tokens {
        guard let tokens else { return SessionSpendReport.Tokens() }
        return SessionSpendReport.Tokens(
            input: Int(tokens.input ?? 0),
            output: Int(tokens.output ?? 0) + Int(tokens.reasoning ?? 0),
            cacheRead: Int(tokens.cache?.read ?? 0),
            cacheWrite5m: Int(tokens.cache?.write ?? 0))
    }

    /// `provider/model`, so a reader downstream can tell an Ollama model on the server's own GPU
    /// from a hosted one with the same name.
    private static func modelKey(_ model: OCSessionModel?) -> String? {
        guard let id = model?.id, !id.isEmpty else { return nil }
        guard let provider = model?.providerID, !provider.isEmpty else { return id }
        return "\(provider)/\(id)"
    }

    private static func projectName(_ directory: String) -> String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private static func title(_ session: OCSession) -> String {
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
