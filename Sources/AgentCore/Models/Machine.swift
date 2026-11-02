import Foundation

/// When a schedule asks, as a person says it: once at a moment, every day, every weekday, every
/// week on one day, or every few hours. The machine reads it in ``MachineSchedule/timeZone``, the
/// zone of the device that made it.
public struct ScheduleRule: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case once, daily, weekdays, weekly, hours
    }

    public var kind: Kind
    public var at: Date?
    public var hour: Int?
    public var minute: Int?
    /// 1 is Sunday, as `Calendar` counts.
    public var weekday: Int?
    /// For ``Kind/hours``: how many hours apart, counted from ``hour`` each day.
    public var every: Int?

    public init(
        kind: Kind, at: Date? = nil, hour: Int? = nil, minute: Int? = nil, weekday: Int? = nil,
        every: Int? = nil
    ) {
        self.kind = kind
        self.at = at
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.every = every
    }

    public static func once(_ at: Date) -> ScheduleRule { ScheduleRule(kind: .once, at: at) }

    public var isRepeating: Bool { kind != .once }

    /// The first time strictly after `moment` this rule asks, read in `calendar`'s zone — the same
    /// arithmetic the machine does, so what a device shows before saving is what the machine keeps.
    public func next(after moment: Date, calendar: Calendar) -> Date? {
        switch kind {
        case .once:
            guard let at, at > moment else { return nil }
            return at
        case .hours:
            guard let every, every > 0, let minute else { return nil }
            let anchor = (hour ?? 0) % every
            guard var candidate = calendar.date(
                bySettingHour: anchor, minute: minute, second: 0, of: calendar.startOfDay(for: moment))
            else { return nil }
            var steps = 0
            while candidate <= moment, steps < 200 {
                guard let stepped = calendar.date(byAdding: .hour, value: every, to: candidate) else {
                    return nil
                }
                candidate = stepped
                steps += 1
            }
            return candidate
        case .daily, .weekdays, .weekly:
            guard let hour, let minute else { return nil }
            var day = calendar.startOfDay(for: moment)
            for _ in 0..<15 {
                if let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                    candidate > moment, accepts(day: day, calendar: calendar)
                {
                    return candidate
                }
                guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = tomorrow
            }
            return nil
        }
    }

    private func accepts(day: Date, calendar: Calendar) -> Bool {
        let weekdayOfDay = calendar.component(.weekday, from: day)
        switch kind {
        case .weekdays: return (2...6).contains(weekdayOfDay)
        case .weekly: return weekdayOfDay == weekday
        default: return true
        }
    }
}

/// One time a schedule asked, or should have.
public struct ScheduleRun: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable, Hashable {
        case running, answered, quiet, failed, missed, caughtUp
    }

    public var id: String
    public var scheduledFor: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var sessionID: String?
    public var outcome: Outcome
    /// How a caught-up run ended: ``Outcome/answered``, ``Outcome/quiet`` or ``Outcome/failed``.
    public var ending: Outcome?
    /// How many asking times passed with nothing asked.
    public var missed: Int
    /// Why a run was missed (`off`, `busy`) or the words a failed one ended with.
    public var failure: String?

    public init(
        id: String, scheduledFor: Date, startedAt: Date? = nil, endedAt: Date? = nil,
        sessionID: String? = nil, outcome: Outcome, ending: Outcome? = nil, missed: Int = 0,
        failure: String? = nil
    ) {
        self.id = id
        self.scheduledFor = scheduledFor
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.sessionID = sessionID
        self.outcome = outcome
        self.ending = ending
        self.missed = missed
        self.failure = failure
    }

    /// How the run settled, a caught-up run read through to its own ending.
    public var settled: Outcome { outcome == .caughtUp ? (ending ?? .running) : outcome }
}

/// A question a machine asks on its own, at a time, again and again or once.
public struct MachineSchedule: Codable, Sendable, Hashable, Identifiable {
    public enum Thread: String, Codable, Sendable, Hashable {
        /// Every run in one conversation, so each sees what the last said.
        case `continue`
        /// A new conversation each time.
        case fresh
    }

    public var id: String
    public var text: String
    public var title: String
    public var model: String?
    public var effort: String?
    public var directory: String?
    public var rule: ScheduleRule
    public var timeZone: String
    public var next: Date?
    public var paused: Bool
    public var thread: Thread
    public var quiet: Bool
    public var sessionID: String?
    public var createdAt: Date
    public var createdBy: String?
    public var runs: [ScheduleRun]

    public init(
        id: String, text: String, title: String, model: String? = nil, effort: String? = nil,
        directory: String? = nil, rule: ScheduleRule, timeZone: String, next: Date?,
        paused: Bool = false, thread: Thread = .continue, quiet: Bool = true, sessionID: String? = nil,
        createdAt: Date, createdBy: String? = nil, runs: [ScheduleRun] = []
    ) {
        self.id = id
        self.text = text
        self.title = title
        self.model = model
        self.effort = effort
        self.directory = directory
        self.rule = rule
        self.timeZone = timeZone
        self.next = next
        self.paused = paused
        self.thread = thread
        self.quiet = quiet
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.runs = runs
    }

    /// Done: a one-off that has asked.
    public var isFinished: Bool { !rule.isRepeating && next == nil }
}

/// A schedule as a device asks the machine to keep it.
public struct ScheduleDraft: Codable, Sendable, Hashable {
    public var text: String
    public var title: String?
    public var model: String?
    public var effort: String?
    public var directory: String?
    public var rule: ScheduleRule
    public var timeZone: String?
    public var thread: MachineSchedule.Thread?
    public var quiet: Bool?
    public var sessionID: String?
    public var createdBy: String?

    public init(
        text: String, title: String? = nil, model: String? = nil, effort: String? = nil,
        directory: String? = nil, rule: ScheduleRule, timeZone: String? = TimeZone.current.identifier,
        thread: MachineSchedule.Thread? = nil, quiet: Bool? = nil, sessionID: String? = nil,
        createdBy: String? = nil
    ) {
        self.text = text
        self.title = title
        self.model = model
        self.effort = effort
        self.directory = directory
        self.rule = rule
        self.timeZone = timeZone
        self.thread = thread
        self.quiet = quiet
        self.sessionID = sessionID
        self.createdBy = createdBy
    }
}

/// What a device changes about a schedule; nil leaves a field as it is.
public struct ScheduleChange: Codable, Sendable, Hashable {
    public var text: String?
    public var title: String?
    public var model: String?
    public var effort: String?
    public var rule: ScheduleRule?
    public var timeZone: String?
    public var paused: Bool?
    public var thread: MachineSchedule.Thread?
    public var quiet: Bool?

    public init(
        text: String? = nil, title: String? = nil, model: String? = nil, effort: String? = nil,
        rule: ScheduleRule? = nil, timeZone: String? = nil, paused: Bool? = nil,
        thread: MachineSchedule.Thread? = nil, quiet: Bool? = nil
    ) {
        self.text = text
        self.title = title
        self.model = model
        self.effort = effort
        self.rule = rule
        self.timeZone = timeZone
        self.paused = paused
        self.thread = thread
        self.quiet = quiet
    }
}

/// An agent a machine can run besides its own: an ACP agent a claude-bridge hosts.
public struct MachineAgent: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable, Hashable {
        case ready, checking, installing, notAdded, needsBrain, needsKey, needsSignIn, missingRuntime
        case failed
    }

    public struct Choice: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var description: String?

        public init(id: String, name: String, description: String? = nil) {
            self.id = id
            self.name = name
            self.description = description
        }
    }

    public struct Key: Codable, Sendable, Hashable {
        public var env: String
        public var name: String
        public var url: String?
        public var set: Bool

        public init(env: String, name: String, url: String? = nil, set: Bool) {
            self.env = env
            self.name = name
            self.url = url
            self.set = set
        }
    }

    public struct SignInMethod: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var description: String?
        /// `terminal` (the machine runs the agent's own sign-in and relays it) or `agent`.
        public var kind: String

        public init(id: String, name: String, description: String? = nil, kind: String) {
            self.id = id
            self.name = name
            self.description = description
            self.kind = kind
        }
    }

    public struct Brain: Codable, Sendable, Hashable {
        /// `local` (a model server on the machine) or `key` (a provider reached with a kept key).
        public var kind: String
        public var name: String
        public var baseURL: String?
        public var model: String?
        public var provider: String?

        public init(kind: String, name: String, baseURL: String? = nil, model: String? = nil, provider: String? = nil) {
            self.kind = kind
            self.name = name
            self.baseURL = baseURL
            self.model = model
            self.provider = provider
        }
    }

    public var id: String
    public var name: String
    public var version: String?
    public var description: String?
    public var icon: String?
    public var website: String?
    /// `found` (on the machine's PATH), `available` (run through npx or uvx), `installed`, `custom`.
    public var source: String
    public var added: Bool
    public var state: State
    /// `node` or `uv`, for ``State/missingRuntime``.
    public var runtime: String?
    /// The agent's own words for what went wrong, kept as a fact.
    public var failure: String?
    public var models: [Choice]
    public var currentModel: String?
    public var efforts: [Choice]
    public var keys: [Key]
    public var signIn: [SignInMethod]
    public var brain: Brain?
    /// Set when the machine can give this agent a brain itself.
    public var brainStyle: String?
    /// `npx`, `uvx` or `download`.
    public var distribution: String?
    public var checkedAt: Date?

    public init(
        id: String, name: String, version: String? = nil, description: String? = nil,
        icon: String? = nil, website: String? = nil, source: String, added: Bool, state: State,
        runtime: String? = nil, failure: String? = nil, models: [Choice] = [],
        currentModel: String? = nil, efforts: [Choice] = [], keys: [Key] = [],
        signIn: [SignInMethod] = [], brain: Brain? = nil, brainStyle: String? = nil,
        distribution: String? = nil, checkedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.website = website
        self.source = source
        self.added = added
        self.state = state
        self.runtime = runtime
        self.failure = failure
        self.models = models
        self.currentModel = currentModel
        self.efforts = efforts
        self.keys = keys
        self.signIn = signIn
        self.brain = brain
        self.brainStyle = brainStyle
        self.distribution = distribution
        self.checkedAt = checkedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        website = try container.decodeIfPresent(String.self, forKey: .website)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "available"
        added = try container.decodeIfPresent(Bool.self, forKey: .added) ?? false
        state =
            (try? container.decode(State.self, forKey: .state)) ?? .failed
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        models = try container.decodeIfPresent([Choice].self, forKey: .models) ?? []
        currentModel = try container.decodeIfPresent(String.self, forKey: .currentModel)
        efforts = try container.decodeIfPresent([Choice].self, forKey: .efforts) ?? []
        keys = try container.decodeIfPresent([Key].self, forKey: .keys) ?? []
        signIn = try container.decodeIfPresent([SignInMethod].self, forKey: .signIn) ?? []
        brain = try container.decodeIfPresent(Brain.self, forKey: .brain)
        brainStyle = try container.decodeIfPresent(String.self, forKey: .brainStyle)
        distribution = try container.decodeIfPresent(String.self, forKey: .distribution)
        checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
    }
}

/// A model server already running on the machine that an agent could think with.
public struct LocalBrain: Codable, Sendable, Hashable, Identifiable {
    public struct Model: Codable, Sendable, Hashable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var id: String
    public var name: String
    public var baseURL: String
    public var models: [Model]

    public init(id: String, name: String, baseURL: String, models: [Model]) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
    }
}

public struct MachineAgentsReport: Codable, Sendable, Hashable {
    public var agents: [MachineAgent]
    public var brains: [LocalBrain]

    public init(agents: [MachineAgent], brains: [LocalBrain]) {
        self.agents = agents
        self.brains = brains
    }
}

/// One agent of the ACP registry, as this machine could run it.
public struct RegistryAgent: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var icon: String?
    public var authors: [String]?
    public var website: String?
    public var distribution: String?
    public var installable: Bool
    public var runtime: String?
    /// `found`, `added` or `installed` when the machine already has it.
    public var here: String?

    public init(
        id: String, name: String, version: String, description: String? = nil, icon: String? = nil,
        authors: [String]? = nil, website: String? = nil, distribution: String? = nil,
        installable: Bool, runtime: String? = nil, here: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.icon = icon
        self.authors = authors
        self.website = website
        self.distribution = distribution
        self.installable = installable
        self.runtime = runtime
        self.here = here
    }
}

/// An agent's sign-in running on the machine, relayed: what it printed, the links and codes in
/// it, and how it ended.
public struct AgentSignInRelay: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        case running, succeeded, failed, cancelled
    }

    public var agent: String
    public var method: String
    public var state: State
    public var lines: [String]
    public var links: [String]
    public var codes: [String]
    public var exitCode: Int32?
    public var startedAt: Date

    public init(
        agent: String, method: String, state: State, lines: [String] = [], links: [String] = [],
        codes: [String] = [], exitCode: Int32? = nil, startedAt: Date = Date()
    ) {
        self.agent = agent
        self.method = method
        self.state = state
        self.lines = lines
        self.links = links
        self.codes = codes
        self.exitCode = exitCode
        self.startedAt = startedAt
    }
}

/// A brain for an agent: a model on a server the machine runs, or a provider and its key.
public struct AgentBrainChoice: Codable, Sendable, Hashable {
    public var kind: String
    public var brain: String?
    public var model: String?
    public var provider: String?
    public var key: String?

    public static func local(brain: String, model: String) -> AgentBrainChoice {
        AgentBrainChoice(kind: "local", brain: brain, model: model, provider: nil, key: nil)
    }

    public static func key(provider: String, key: String) -> AgentBrainChoice {
        AgentBrainChoice(kind: "key", brain: nil, model: nil, provider: provider, key: key)
    }
}

/// A server that keeps schedules and asks them itself. claude-bridge and omp-bridge do.
public protocol MachineScheduling: Sendable {
    /// Nil when this server cannot say — it keeps no schedules.
    func machineSchedules() async throws -> [MachineSchedule]?
    func createSchedule(_ draft: ScheduleDraft) async throws -> MachineSchedule
    func updateSchedule(_ id: String, _ change: ScheduleChange) async throws -> MachineSchedule
    func deleteSchedule(_ id: String) async throws
    func runSchedule(_ id: String) async throws -> MachineSchedule
}

/// A server that hosts ACP agents beside its own. claude-bridge does.
public protocol MachineAgentHosting: Sendable {
    /// Nil when this server hosts no other agents.
    func machineAgents(refreshBrains: Bool) async throws -> MachineAgentsReport?
    func agentRegistry() async throws -> [RegistryAgent]
    func addAgent(_ id: String) async throws -> MachineAgent
    func removeAgent(_ id: String) async throws
    func checkAgent(_ id: String) async throws -> MachineAgent
    func installAgent(_ id: String) async throws -> MachineAgent
    func setAgentKey(_ id: String, env: String, value: String) async throws -> MachineAgent
    func setAgentBrain(_ id: String, _ choice: AgentBrainChoice) async throws -> MachineAgent
    func startAgentSignIn(_ id: String, method: String) async throws -> AgentSignInRelay
    func agentSignIn(_ id: String) async throws -> AgentSignInRelay?
    func sendAgentSignIn(_ id: String, text: String) async throws
    func cancelAgentSignIn(_ id: String) async throws
}
