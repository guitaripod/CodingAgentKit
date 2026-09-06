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

    public init(tasks: Int, task: String? = nil) {
        self.tasks = tasks
        self.task = task
    }

    /// The wire shape as one value: a count the server left out or put at zero is no work at all.
    public static func reported(tasks: Int?, task: String?) -> BackgroundWork? {
        guard let tasks, tasks > 0 else { return nil }
        return BackgroundWork(tasks: tasks, task: task)
    }
}
