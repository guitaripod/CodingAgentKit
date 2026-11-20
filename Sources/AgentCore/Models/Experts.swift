import Foundation

/// A device or service an expert works with, as described, and what the machine found when it
/// last proved it. A machine says what it found as states and keys; a client words them.
public struct ExpertBenchItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable, CaseIterable {
        case appleDevice, command, port
    }

    public enum State: String, Codable, Sendable, Hashable {
        case ready, absent, locked, held, unknown
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// For an Apple device: its UDID, its CoreDevice identifier or its name.
    public var identifier: String?
    public var command: String?
    public var host: String?
    public var port: Int?
    /// The lock file the expert holds around work on this item.
    public var lock: String?
    public var state: State?
    /// `name`, `model`, `os`, `osVersion`, `transport` (`wired`, `network`, `usb`), `output`.
    public var facts: [String: String]?
    public var holder: ExpertBenchHolder?
    public var checkedAt: Date?

    public init(
        id: String = UUID().uuidString, name: String, kind: Kind, identifier: String? = nil, command: String? = nil,
        host: String? = nil, port: Int? = nil, lock: String? = nil, state: State? = nil,
        facts: [String: String]? = nil, holder: ExpertBenchHolder? = nil, checkedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.identifier = identifier
        self.command = command
        self.host = host
        self.port = port
        self.lock = lock
        self.state = state
        self.facts = facts
        self.holder = holder
        self.checkedAt = checkedAt
    }

    /// The item as a change sends it: its description without anything a proof found.
    public var described: ExpertBenchItem {
        ExpertBenchItem(
            id: id, name: name, kind: kind, identifier: identifier, command: command, host: host, port: port,
            lock: lock)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = (try? values.decode(Kind.self, forKey: .kind)) ?? .command
        identifier = try values.decodeIfPresent(String.self, forKey: .identifier)
        command = try values.decodeIfPresent(String.self, forKey: .command)
        host = try values.decodeIfPresent(String.self, forKey: .host)
        port = try values.decodeIfPresent(Int.self, forKey: .port)
        lock = try values.decodeIfPresent(String.self, forKey: .lock)
        state = (try? values.decodeIfPresent(String.self, forKey: .state)).flatMap { $0.flatMap(State.init(rawValue:)) }
        facts = try? values.decodeIfPresent([String: String].self, forKey: .facts)
        holder = try? values.decodeIfPresent(ExpertBenchHolder.self, forKey: .holder)
        checkedAt = try? values.decodeIfPresent(Date.self, forKey: .checkedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, identifier, command, host, port, lock, state, facts, holder, checkedAt
    }
}

public struct ExpertBenchHolder: Codable, Sendable, Hashable {
    public var sessionID: String?
    public var title: String?
    public var pid: Int32?

    public init(sessionID: String? = nil, title: String? = nil, pid: Int32? = nil) {
        self.sessionID = sessionID
        self.title = title
        self.pid = pid
    }
}

/// A number a guard reads out of its command's output: the last match of `pattern`'s first group.
public struct ExpertGuardMetric: Codable, Sendable, Hashable {
    public var pattern: String
    public var atMost: Double?
    public var atLeast: Double?
    public var unit: String?

    public init(pattern: String, atMost: Double? = nil, atLeast: Double? = nil, unit: String? = nil) {
        self.pattern = pattern
        self.atMost = atMost
        self.atLeast = atLeast
        self.unit = unit
    }
}

public struct ExpertGuardRun: Codable, Sendable, Hashable {
    public enum Failure: String, Codable, Sendable, Hashable {
        case timeout, metric, exit, missing
    }

    public var at: Date
    public var passed: Bool
    public var seconds: Double
    public var exitCode: Int32?
    public var value: Double?
    public var output: String?
    public var failure: Failure?

    public init(
        at: Date, passed: Bool, seconds: Double, exitCode: Int32? = nil, value: Double? = nil, output: String? = nil,
        failure: Failure? = nil
    ) {
        self.at = at
        self.passed = passed
        self.seconds = seconds
        self.exitCode = exitCode
        self.value = value
        self.output = output
        self.failure = failure
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        at = try values.decode(Date.self, forKey: .at)
        passed = try values.decode(Bool.self, forKey: .passed)
        seconds = (try? values.decode(Double.self, forKey: .seconds)) ?? 0
        exitCode = try? values.decodeIfPresent(Int32.self, forKey: .exitCode)
        value = try? values.decodeIfPresent(Double.self, forKey: .value)
        output = try? values.decodeIfPresent(String.self, forKey: .output)
        failure = (try? values.decodeIfPresent(String.self, forKey: .failure)).flatMap { $0.flatMap(Failure.init(rawValue:)) }
    }

    private enum CodingKeys: String, CodingKey {
        case at, passed, seconds, exitCode, value, output, failure
    }
}

/// A command that has to keep passing for an expert's world to be well.
public struct ExpertGuard: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var command: String
    public var directory: String?
    public var metric: ExpertGuardMetric?
    /// Seconds a run is given before it is stopped and counted as failed.
    public var timeout: Int?
    public var last: ExpertGuardRun?
    public var history: [ExpertGuardRun]?
    public var running: Bool?

    public init(
        id: String = UUID().uuidString, name: String, command: String, directory: String? = nil,
        metric: ExpertGuardMetric? = nil, timeout: Int? = nil, last: ExpertGuardRun? = nil,
        history: [ExpertGuardRun]? = nil, running: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.directory = directory
        self.metric = metric
        self.timeout = timeout
        self.last = last
        self.history = history
        self.running = running
    }

    public var described: ExpertGuard {
        ExpertGuard(id: id, name: name, command: command, directory: directory, metric: metric, timeout: timeout)
    }

    /// The latest run failed.
    public var isFailing: Bool { last.map { !$0.passed } ?? false }

    /// When the guard began failing: the oldest run in the unbroken stretch of failures that ends
    /// with the latest one. Nil when every run the machine kept failed, since the stretch began
    /// before the history does and its start is not known.
    public var failingSince: Date? {
        guard isFailing else { return nil }
        let runs = history ?? []
        var since = last?.at
        for run in runs {
            guard !run.passed else { return since }
            since = run.at
        }
        return runs.count >= Self.keptRuns ? nil : since
    }

    /// How many runs a machine keeps for one guard.
    public static let keptRuns = 30
}

public struct ExpertNotebookFacts: Codable, Sendable, Hashable {
    public var path: String
    public var adopted: Bool
    public var notes: Int
    public var stale: Int
    public var retired: Int

    public init(path: String, adopted: Bool, notes: Int, stale: Int, retired: Int) {
        self.path = path
        self.adopted = adopted
        self.notes = notes
        self.stale = stale
        self.retired = retired
    }
}

/// One fact in an expert's notebook.
public struct ExpertNote: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var summary: String
    public var body: String?
    public var type: String?
    public var written: Date?
    public var confirmed: Date?
    public var source: String?
    public var stale: Bool
    public var retired: ExpertNoteRetirement?

    public init(
        id: String, title: String, summary: String, body: String? = nil, type: String? = nil, written: Date? = nil,
        confirmed: Date? = nil, source: String? = nil, stale: Bool = false, retired: ExpertNoteRetirement? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.body = body
        self.type = type
        self.written = written
        self.confirmed = confirmed
        self.source = source
        self.stale = stale
        self.retired = retired
    }

    /// When the note was last written or confirmed.
    public var lastTouched: Date? { [written, confirmed].compactMap { $0 }.max() }

    /// The task the note came from, when an expert's debrief wrote it: `tailscode-expert:<expert>:<session>`.
    public var sourceSession: String? {
        guard let source, source.hasPrefix("tailscode-expert:") else { return nil }
        let parts = source.split(separator: ":")
        guard parts.count == 3, parts[2] != "made" else { return nil }
        return String(parts[2])
    }
}

public struct ExpertNoteRetirement: Codable, Sendable, Hashable {
    public var at: Date?
    public var reason: String?

    public init(at: Date? = nil, reason: String? = nil) {
        self.at = at
        self.reason = reason
    }
}

public struct ExpertJournalEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var sessionID: String?
    public var title: String
    public var at: Date
    public var outcome: String
    public var measured: [String]
    public var commits: [String]

    public init(
        id: String = UUID().uuidString, sessionID: String? = nil, title: String, at: Date, outcome: String,
        measured: [String] = [], commits: [String] = []
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.at = at
        self.outcome = outcome
        self.measured = measured
        self.commits = commits
    }
}

/// A change to the notebook an expert proposes when a task ends.
public struct ExpertProposal: Codable, Sendable, Hashable, Identifiable {
    public enum Operation: String, Codable, Sendable, Hashable {
        case add, change, retire
    }

    public enum State: String, Codable, Sendable, Hashable {
        case pending, accepted, skipped
    }

    public var id: String
    public var op: Operation
    public var note: String?
    public var title: String
    public var summary: String
    public var body: String
    public var reason: String
    public var state: State

    public init(
        id: String = UUID().uuidString, op: Operation, note: String? = nil, title: String, summary: String,
        body: String, reason: String, state: State = .pending
    ) {
        self.id = id
        self.op = op
        self.note = note
        self.title = title
        self.summary = summary
        self.body = body
        self.reason = reason
        self.state = state
    }
}

public struct ExpertDebrief: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable, Hashable {
        case drafting, open, settled, failed
    }

    public var sessionID: String
    public var expertID: String
    public var at: Date
    public var coveredTurns: Int
    public var state: State
    public var failure: String?
    public var journal: ExpertJournalEntry?
    public var proposals: [ExpertProposal]

    public init(
        sessionID: String, expertID: String, at: Date, coveredTurns: Int, state: State, failure: String? = nil,
        journal: ExpertJournalEntry? = nil, proposals: [ExpertProposal] = []
    ) {
        self.sessionID = sessionID
        self.expertID = expertID
        self.at = at
        self.coveredTurns = coveredTurns
        self.state = state
        self.failure = failure
        self.journal = journal
        self.proposals = proposals
    }

    public var pending: [ExpertProposal] { state == .open ? proposals.filter { $0.state == .pending } : [] }
}

public struct ExpertTaskRef: Codable, Sendable, Hashable, Identifiable {
    public var sessionID: String
    public var title: String
    public var updatedAt: Date
    public var active: Bool
    public var debrief: ExpertDebrief.State?

    public var id: String { sessionID }

    public init(sessionID: String, title: String, updatedAt: Date, active: Bool, debrief: ExpertDebrief.State? = nil) {
        self.sessionID = sessionID
        self.title = title
        self.updatedAt = updatedAt
        self.active = active
        self.debrief = debrief
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        title = try values.decode(String.self, forKey: .title)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        active = (try? values.decode(Bool.self, forKey: .active)) ?? false
        debrief = (try? values.decodeIfPresent(String.self, forKey: .debrief)).flatMap { $0.flatMap(ExpertDebrief.State.init(rawValue:)) }
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, title, updatedAt, active, debrief
    }
}

/// An expert a machine keeps: a standing role whose every task is a fresh conversation that starts
/// with its brief and ends with a debrief.
public struct MachineExpert: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var glyph: String
    /// `blue`, `orange`, `green`, `purple`, `pink`, `teal`, `indigo`, `red`, `yellow` or `gray`.
    public var hue: String
    public var purpose: String
    public var directory: String?
    public var model: String?
    public var effort: String?
    public var charter: String
    public var skills: [String]
    public var notebookPath: String?
    public var bench: [ExpertBenchItem]
    public var guards: [ExpertGuard]
    public var guardRule: ScheduleRule?
    public var guardNext: Date?
    public var timeZone: String
    public var createdAt: Date
    public var updatedAt: Date
    public var notebook: ExpertNotebookFacts
    public var journal: [ExpertJournalEntry]
    public var task: ExpertTaskRef?
    public var tasks: [ExpertTaskRef]
    public var pending: Int
    public var briefTokens: Int
    public var watches: [String]

    public init(
        id: String, name: String, glyph: String, hue: String, purpose: String, directory: String? = nil,
        model: String? = nil, effort: String? = nil, charter: String = "", skills: [String] = [],
        notebookPath: String? = nil, bench: [ExpertBenchItem] = [], guards: [ExpertGuard] = [],
        guardRule: ScheduleRule? = nil, guardNext: Date? = nil, timeZone: String = TimeZone.current.identifier,
        createdAt: Date = Date(), updatedAt: Date = Date(),
        notebook: ExpertNotebookFacts = ExpertNotebookFacts(path: "", adopted: false, notes: 0, stale: 0, retired: 0),
        journal: [ExpertJournalEntry] = [], task: ExpertTaskRef? = nil, tasks: [ExpertTaskRef] = [], pending: Int = 0,
        briefTokens: Int = 0, watches: [String] = []
    ) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.hue = hue
        self.purpose = purpose
        self.directory = directory
        self.model = model
        self.effort = effort
        self.charter = charter
        self.skills = skills
        self.notebookPath = notebookPath
        self.bench = bench
        self.guards = guards
        self.guardRule = guardRule
        self.guardNext = guardNext
        self.timeZone = timeZone
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notebook = notebook
        self.journal = journal
        self.task = task
        self.tasks = tasks
        self.pending = pending
        self.briefTokens = briefTokens
        self.watches = watches
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        glyph = (try? values.decode(String.self, forKey: .glyph)) ?? String(name.prefix(2))
        hue = (try? values.decode(String.self, forKey: .hue)) ?? "blue"
        purpose = (try? values.decode(String.self, forKey: .purpose)) ?? ""
        directory = try? values.decodeIfPresent(String.self, forKey: .directory)
        model = try? values.decodeIfPresent(String.self, forKey: .model)
        effort = try? values.decodeIfPresent(String.self, forKey: .effort)
        charter = (try? values.decode(String.self, forKey: .charter)) ?? ""
        skills = (try? values.decode([String].self, forKey: .skills)) ?? []
        notebookPath = try? values.decodeIfPresent(String.self, forKey: .notebookPath)
        bench = (try? values.decode([Lenient<ExpertBenchItem>].self, forKey: .bench))?.compactMap(\.value) ?? []
        guards = (try? values.decode([Lenient<ExpertGuard>].self, forKey: .guards))?.compactMap(\.value) ?? []
        guardRule = try? values.decodeIfPresent(ScheduleRule.self, forKey: .guardRule)
        guardNext = try? values.decodeIfPresent(Date.self, forKey: .guardNext)
        timeZone = (try? values.decode(String.self, forKey: .timeZone)) ?? TimeZone.current.identifier
        createdAt = (try? values.decode(Date.self, forKey: .createdAt)) ?? .distantPast
        updatedAt = (try? values.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        notebook =
            (try? values.decode(ExpertNotebookFacts.self, forKey: .notebook))
            ?? ExpertNotebookFacts(path: "", adopted: false, notes: 0, stale: 0, retired: 0)
        journal = (try? values.decode([Lenient<ExpertJournalEntry>].self, forKey: .journal))?.compactMap(\.value) ?? []
        task = try? values.decodeIfPresent(ExpertTaskRef.self, forKey: .task)
        tasks = (try? values.decode([Lenient<ExpertTaskRef>].self, forKey: .tasks))?.compactMap(\.value) ?? []
        pending = (try? values.decode(Int.self, forKey: .pending)) ?? 0
        briefTokens = (try? values.decode(Int.self, forKey: .briefTokens)) ?? 0
        watches = (try? values.decode([String].self, forKey: .watches)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, glyph, hue, purpose, directory, model, effort, charter, skills, notebookPath, bench, guards
        case guardRule, guardNext, timeZone, createdAt, updatedAt, notebook, journal, task, tasks, pending
        case briefTokens, watches
    }

    public var failingGuards: [ExpertGuard] { guards.filter(\.isFailing) }
    public var runningGuards: Bool { guards.contains { $0.running == true } }
}

/// One element of a list read on its own, so one this client cannot read is left out rather than
/// losing the rest.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// A note written into a notebook as an expert is made.
public struct ExpertDraftNote: Codable, Sendable, Hashable, Identifiable {
    public var id: String { title }
    public var title: String
    public var summary: String
    public var body: String
    public var type: String?
    /// False for a fact that held only on the day it was drafted from; offered unticked.
    public var lasting: Bool?

    public init(title: String, summary: String, body: String, type: String? = nil, lasting: Bool? = true) {
        self.title = title
        self.summary = summary
        self.body = body
        self.type = type
        self.lasting = lasting
    }
}

/// An expert to make, or a draft one to review before making it.
public struct ExpertDraft: Codable, Sendable, Hashable {
    public var name: String
    public var glyph: String?
    public var hue: String?
    public var purpose: String?
    public var directory: String?
    public var model: String?
    public var effort: String?
    public var charter: String?
    public var skills: [String]?
    public var notebookPath: String?
    public var bench: [ExpertBenchItem]?
    public var guards: [ExpertGuard]?
    public var guardRule: ScheduleRule?
    public var timeZone: String?
    public var notes: [ExpertDraftNote]?

    public init(
        name: String, glyph: String? = nil, hue: String? = nil, purpose: String? = nil, directory: String? = nil,
        model: String? = nil, effort: String? = nil, charter: String? = nil, skills: [String]? = nil,
        notebookPath: String? = nil, bench: [ExpertBenchItem]? = nil, guards: [ExpertGuard]? = nil,
        guardRule: ScheduleRule? = nil, timeZone: String? = nil, notes: [ExpertDraftNote]? = nil
    ) {
        self.name = name
        self.glyph = glyph
        self.hue = hue
        self.purpose = purpose
        self.directory = directory
        self.model = model
        self.effort = effort
        self.charter = charter
        self.skills = skills
        self.notebookPath = notebookPath
        self.bench = bench
        self.guards = guards
        self.guardRule = guardRule
        self.timeZone = timeZone
        self.notes = notes
    }
}

/// What changes about an expert; nil leaves a part as it is. An empty string clears a folder,
/// model or effort.
public struct ExpertChange: Codable, Sendable, Hashable {
    public var name: String?
    public var glyph: String?
    public var hue: String?
    public var purpose: String?
    public var directory: String?
    public var model: String?
    public var effort: String?
    public var charter: String?
    public var skills: [String]?
    public var notebookPath: String?
    public var bench: [ExpertBenchItem]?
    public var guards: [ExpertGuard]?
    public var guardRule: ScheduleRule?
    /// True runs the guards only when asked, clearing the rule.
    public var guardsOnDemand: Bool?
    public var timeZone: String?

    public init(
        name: String? = nil, glyph: String? = nil, hue: String? = nil, purpose: String? = nil,
        directory: String? = nil, model: String? = nil, effort: String? = nil, charter: String? = nil,
        skills: [String]? = nil, notebookPath: String? = nil, bench: [ExpertBenchItem]? = nil,
        guards: [ExpertGuard]? = nil, guardRule: ScheduleRule? = nil, guardsOnDemand: Bool? = nil,
        timeZone: String? = nil
    ) {
        self.name = name
        self.glyph = glyph
        self.hue = hue
        self.purpose = purpose
        self.directory = directory
        self.model = model
        self.effort = effort
        self.charter = charter
        self.skills = skills
        self.notebookPath = notebookPath
        self.bench = bench.map { $0.map(\.described) }
        self.guards = guards.map { $0.map(\.described) }
        self.guardRule = guardRule
        self.guardsOnDemand = guardsOnDemand
        self.timeZone = timeZone
    }
}

public struct ExpertTaskRequest: Codable, Sendable, Hashable {
    public var text: String
    public var title: String?
    public var model: String?
    public var effort: String?
    public var directory: String?

    public init(text: String, title: String? = nil, model: String? = nil, effort: String? = nil, directory: String? = nil) {
        self.text = text
        self.title = title
        self.model = model
        self.effort = effort
        self.directory = directory
    }
}

public struct ExpertTaskStarted: Sendable, Hashable {
    public var session: AgentSession
    /// The task waits behind this many turns on the machine.
    public var queued: Int?

    public init(session: AgentSession, queued: Int? = nil) {
        self.session = session
        self.queued = queued
    }
}

public struct ExpertDebriefDecision: Codable, Sendable, Hashable {
    public struct Edit: Codable, Sendable, Hashable {
        public var title: String?
        public var summary: String?
        public var body: String?

        public init(title: String? = nil, summary: String? = nil, body: String? = nil) {
            self.title = title
            self.summary = summary
            self.body = body
        }
    }

    public var accepted: [String]
    /// The proposals skipped; nil skips every pending one not accepted.
    public var skipped: [String]?
    public var edits: [String: Edit]?

    public init(accepted: [String], skipped: [String]? = nil, edits: [String: Edit]? = nil) {
        self.accepted = accepted
        self.skipped = skipped
        self.edits = edits
    }
}

public struct ExpertSkill: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var path: String

    public init(name: String, description: String, path: String) {
        self.name = name
        self.description = description
        self.path = path
    }
}

public struct ExpertBriefPreview: Codable, Sendable, Hashable {
    public var text: String
    public var tokens: Int

    public init(text: String, tokens: Int) {
        self.text = text
        self.tokens = tokens
    }
}

/// A server that keeps experts. claude-bridge does from protocol 1.
public protocol MachineExperts: Sendable {
    /// Nil when this server keeps no experts.
    func machineExperts() async throws -> [MachineExpert]?
    /// One expert; `prove` asks the machine to prove its bench first.
    func machineExpert(_ id: String, prove: Bool) async throws -> MachineExpert
    func createExpert(_ draft: ExpertDraft) async throws -> MachineExpert
    func updateExpert(_ id: String, _ change: ExpertChange) async throws -> MachineExpert
    func deleteExpert(_ id: String) async throws
    /// A draft expert from a conversation or from a skill on the machine. Nothing is saved.
    func draftExpert(session: String?, skill: String?) async throws -> ExpertDraft
    func expertSkills() async throws -> [ExpertSkill]
    func expertNotes(_ id: String, retired: Bool) async throws -> [ExpertNote]
    func expertNote(_ id: String, note: String) async throws -> ExpertNote
    func expertJournal(_ id: String) async throws -> [ExpertJournalEntry]
    func expertBrief(_ id: String) async throws -> ExpertBriefPreview
    func runExpertGuards(_ id: String, guardID: String?) async throws -> MachineExpert
    func startExpertTask(_ id: String, _ request: ExpertTaskRequest) async throws -> ExpertTaskStarted
    /// The task's debrief, nil when it has none yet.
    func expertDebrief(sessionID: String) async throws -> ExpertDebrief?
    /// Finishes the task: asks the machine for its debrief, which drafts in the background.
    func finishExpertTask(sessionID: String) async throws -> ExpertDebrief
    func decideExpertDebrief(sessionID: String, _ decision: ExpertDebriefDecision) async throws -> ExpertDebrief
}
