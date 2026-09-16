import Foundation

/// Work the agent's own process is carrying between turns: a command the model started and stepped
/// back from, an agent it backgrounded. No turn is open, the prompt is free to type into, and the
/// machine is still working for this conversation — and when the work ends the agent speaks again
/// on its own. A client that can only say running or idle has to call this idle, which is how a
/// session running a two-hour test reads as a session that finished.
///
/// The server reports it as a level rather than as edges — how many tasks are live right now, and
/// what the one task is when there is exactly one — so a missed frame can never leave a stale
/// indicator standing. Absent means none; a backend with no such notion never reports one.
public struct BackgroundWork: Sendable, Hashable, Codable {
    public var tasks: Int
    /// The task in the agent's own words, when exactly one is running; nil for several, or when
    /// the server did not say.
    public var task: String?
    /// When the oldest of the tasks began, so a row can say how long the machine has been at it.
    /// A build that started a minute ago and a shell that has sat there since morning are not
    /// the same badge. Nil from a server that does not say.
    public var since: Date?
    /// The server's own finding that the work is stuck: a shell past the budget the model gave
    /// it that has spent no CPU time and written nothing for a whole window. A server that ends
    /// such shells itself reports this only briefly; one told not to reports it until somebody
    /// stops the work.
    public var stalled: Bool

    public init(tasks: Int, task: String? = nil, since: Date? = nil, stalled: Bool = false) {
        self.tasks = tasks
        self.task = task
        self.since = since
        self.stalled = stalled
    }

    private enum CodingKeys: String, CodingKey {
        case tasks, task, since, stalled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode(Int.self, forKey: .tasks)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        stalled = try c.decodeIfPresent(Bool.self, forKey: .stalled) ?? false
    }

    /// The wire shape as one value: a count the server left out or put at zero is no work at all.
    public static func reported(
        tasks: Int?, task: String?, since: Date? = nil, stalled: Bool? = nil
    ) -> BackgroundWork? {
        guard let tasks, tasks > 0 else { return nil }
        return BackgroundWork(tasks: tasks, task: task, since: since, stalled: stalled ?? false)
    }

    /// How long the machine has been at it, as of `now`. Nil where the server never said.
    public func age(at now: Date = Date()) -> TimeInterval? {
        since.map { max(0, now.timeIntervalSince($0)) }
    }
}
