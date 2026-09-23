import Foundation

/// What a server says about its own version, and about the newer one it could move to.
///
/// A server reached over a tailnet from a phone is a machine the person holding the phone often
/// cannot open a terminal on. So the update is something the server offers and the client asks
/// for, rather than a command someone has to remember to run.
public struct ServerUpdate: Sendable, Hashable, Codable {
    /// Phases a running update passes through. Reported by the server so a client can say what is
    /// happening rather than spinning blindly through a restart.
    public enum Phase: String, Sendable, Hashable, Codable {
        case idle
        case running
        case building
        /// Built, and holding until the machine has nothing running that a restart would destroy.
        /// The wait is a state rather than a silence, because it can outlast the build.
        case waiting
        case restarting
        case succeeded
        case failed
    }

    /// What stands between a machine and a one-press update, in a shape that can be listed.
    ///
    /// The sentence alone was never actionable — "the checkout has uncommitted changes" does not
    /// say which — and a raw `git status` is thousands of lines that three clients would persist.
    /// So the kind and the sentence are what a person acknowledges, and the items are what they act
    /// on.
    public struct Obstacle: Sendable, Hashable, Codable {
        public var kind: String
        public var summary: String
        public var items: [String]
        public var more: Int

        public init(kind: String, summary: String, items: [String] = [], more: Int = 0) {
            self.kind = kind
            self.summary = summary
            self.items = items
            self.more = more
        }
    }

    /// Whether anything a restart would destroy is happening on that machine right now.
    public struct Busy: Sendable, Hashable, Codable {
        public var quiet: Bool
        public var turns: Int
        public var reason: String?

        public init(quiet: Bool, turns: Int = 0, reason: String? = nil) {
            self.quiet = quiet
            self.turns = turns
            self.reason = reason
        }
    }

    /// What the machine does about updates when nobody is asking. The setting belongs to the
    /// machine, so every client reads back the same answer rather than its own last request.
    public struct Automation: Sendable, Hashable, Codable {
        public var enabled: Bool
        public var lastTakenAt: Date?
        public var lastTarget: String?
        public var nextLookAt: Date?
        /// Why nothing is being taken right now, when something otherwise could be.
        public var holdingOff: String?

        public init(
            enabled: Bool, lastTakenAt: Date? = nil, lastTarget: String? = nil,
            nextLookAt: Date? = nil, holdingOff: String? = nil
        ) {
            self.enabled = enabled
            self.lastTakenAt = lastTakenAt
            self.lastTarget = lastTarget
            self.nextLookAt = nextLookAt
            self.holdingOff = holdingOff
        }
    }

    /// What the server actually consulted about a newer build, said outright rather than inferred.
    ///
    /// `updateAvailable: false` used to mean four different things — genuinely current, the client
    /// asked not to check, the machine has no checkout to check with, or the fetch failed — and a
    /// client could not tell them apart. This is the difference, reported by the only party that
    /// knows it.
    public struct RemoteCheck: Sendable, Hashable, Codable {
        /// Whether this answer consulted the remote at all.
        public var checked: Bool
        /// Whether consulting it worked.
        public var ok: Bool
        public var at: Date?
        /// Why it did not, in words worth showing a person.
        public var error: String?
        /// The ref it compared against — a machine deliberately on a feature branch is not behind
        /// the same line as the others, and folding them into one number would say it was.
        public var ref: String?

        public init(
            checked: Bool, ok: Bool, at: Date? = nil, error: String? = nil, ref: String? = nil
        ) {
            self.checked = checked
            self.ok = ok
            self.at = at
            self.error = error
            self.ref = ref
        }
    }

    /// One update or restart as the machine ran it, from the press to the way it ended.
    ///
    /// The phase alone could never say whose job a `succeeded` was, or what it landed on: a client
    /// following a press read the same word for its own update and for last week's. A job has an
    /// identity, the step it is on, and an outcome written by the process that came back — so a
    /// client can follow exactly the job it started, pick up one another device or the machine's
    /// own automation started, and say what it became.
    public struct Job: Sendable, Hashable, Codable {
        public enum Kind: String, Sendable, Hashable, Codable {
            /// Fetch, build and restart onto the new build.
            case update
            /// Load a build already on the machine's disk.
            case restart
        }

        public enum Step: String, Sendable, Hashable, Codable {
            case download
            case build
            /// Built, and holding until nothing is running that a restart would stop.
            case waitForIdle
            case restart
            case done
        }

        public enum Outcome: String, Sendable, Hashable, Codable {
            /// The process that came back is running the build the job made.
            case succeeded
            case failed
            /// The build is on the machine and the loading of it is owed — nothing there would
            /// start the bridge again, or the machine never went idle.
            case deferred
        }

        public var id: String
        public var kind: Kind
        /// Started by the machine's own policy rather than by anybody's press.
        public var automatic: Bool
        /// Nil when the machine named a step this client has never heard of.
        public var step: Step?
        public var outcome: Outcome?
        /// What the machine was running when the job began.
        public var from: String?
        /// What the job set out to install.
        public var target: String?
        /// What the machine was running once the job ended.
        public var landed: String?
        public var reason: String?
        public var startedAt: Date?
        public var stepStartedAt: Date?
        public var finishedAt: Date?

        public init(
            id: String, kind: Kind = .update, automatic: Bool = false, step: Step? = nil,
            outcome: Outcome? = nil, from: String? = nil, target: String? = nil,
            landed: String? = nil, reason: String? = nil, startedAt: Date? = nil,
            stepStartedAt: Date? = nil, finishedAt: Date? = nil
        ) {
            self.id = id
            self.kind = kind
            self.automatic = automatic
            self.step = step
            self.outcome = outcome
            self.from = from
            self.target = target
            self.landed = landed
            self.reason = reason
            self.startedAt = startedAt
            self.stepStartedAt = stepStartedAt
            self.finishedAt = finishedAt
        }

        /// A job is over once the machine wrote how it ended — or once it stamped an end without a
        /// word this client knows, which is still an end.
        public var isFinished: Bool { outcome != nil || finishedAt != nil || step == .done }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            kind =
                (try? container.decodeIfPresent(String.self, forKey: .kind))
                .flatMap(Kind.init(rawValue:)) ?? .update
            automatic = (try? container.decodeIfPresent(Bool.self, forKey: .automatic)) ?? false
            step =
                (try? container.decodeIfPresent(String.self, forKey: .step))
                .flatMap(Step.init(rawValue:))
            outcome =
                (try? container.decodeIfPresent(String.self, forKey: .outcome))
                .flatMap(Outcome.init(rawValue:))
            from = try? container.decodeIfPresent(String.self, forKey: .from)
            target = try? container.decodeIfPresent(String.self, forKey: .target)
            landed = try? container.decodeIfPresent(String.self, forKey: .landed)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            startedAt = try? container.decodeIfPresent(Date.self, forKey: .startedAt)
            stepStartedAt = try? container.decodeIfPresent(Date.self, forKey: .stepStartedAt)
            finishedAt = try? container.decodeIfPresent(Date.self, forKey: .finishedAt)
        }
    }

    /// What the newer build is, in words a person reads rather than a count of commits.
    public struct Release: Sendable, Hashable, Codable {
        /// One release's worth of change, written for people — the project's own changelog where it
        /// has one, and the headlines of its commits where it does not.
        public struct Note: Sendable, Hashable, Codable {
            /// Nil for changes past the newest release, which no version names yet.
            public var version: String?
            public var date: String?
            public var items: [String]

            public init(version: String?, date: String? = nil, items: [String]) {
                self.version = version
                self.date = date
                self.items = items
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                version = try? container.decodeIfPresent(String.self, forKey: .version)
                date = try? container.decodeIfPresent(String.self, forKey: .date)
                items = (try? container.decodeIfPresent([String].self, forKey: .items)) ?? []
            }
        }

        /// The newest release tag the project's head carries.
        public var version: String?
        /// Commits the head has past that tag.
        public var commitsPastTag: Int?
        /// Everything newer than what the machine runs, newest first.
        public var notes: [Note]

        public init(version: String?, commitsPastTag: Int? = nil, notes: [Note] = []) {
            self.version = version
            self.commitsPastTag = commitsPastTag
            self.notes = notes
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try? container.decodeIfPresent(String.self, forKey: .version)
            commitsPastTag = try? container.decodeIfPresent(Int.self, forKey: .commitsPastTag)
            notes = (try? container.decodeIfPresent([Note].self, forKey: .notes)) ?? []
        }
    }

    public var version: String
    /// The version of the binary that is executing, stamped when it was built.
    ///
    /// `version` describes the *checkout* — it moves when somebody checks out a branch on that
    /// machine, and it runs ahead of the process for the whole stretch between a build and a
    /// restart. This one is a fact about the running program.
    public var running: String?
    /// A build has landed that this process is not running yet.
    public var restartRequired: Bool
    public var builtAt: Date?
    public var remote: RemoteCheck?
    /// Commits this checkout has that its upstream does not. Any at all means an update cannot
    /// fast-forward, whatever `canUpdate` says.
    public var ahead: Int?
    public var commit: String?
    public var latestVersion: String?
    public var latestCommit: String?
    public var updateAvailable: Bool
    /// How many commits this install is behind, when the server can tell.
    public var behind: Int?
    /// Subjects of the commits an update would bring in, newest first.
    public var changes: [String]
    public var canUpdate: Bool
    /// Why the server cannot update itself, in words worth showing a person.
    public var reason: String?
    /// What supervises the server: `systemd`, `launchd`, or `manual`.
    public var manager: String
    public var source: String?
    public var phase: Phase
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Tail of the update's own log, for when it fails.
    public var log: String?
    public var obstacle: Obstacle?
    public var busy: Busy?
    /// When the machine started waiting for itself to go quiet before loading a build it has
    /// already made.
    public var waitingSince: Date?
    /// Whether one press can put that process onto a build already sitting on its disk. False
    /// without a supervisor, because a bridge that exits with nothing to start it again is a
    /// machine no client can reach.
    public var canRestart: Bool
    public var automation: Automation?
    /// Which Swift would do the building there, so a module-format failure is readable.
    public var toolchain: String?
    /// The job in flight, or the last one to finish. Absent from a bridge older than jobs.
    public var job: Job?
    /// What the newer build carries. Absent unless the answer consulted the project.
    public var release: Release?

    public init(
        version: String, running: String? = nil, restartRequired: Bool = false,
        builtAt: Date? = nil, remote: RemoteCheck? = nil, ahead: Int? = nil,
        commit: String? = nil, latestVersion: String? = nil,
        latestCommit: String? = nil, updateAvailable: Bool = false, behind: Int? = nil,
        changes: [String] = [], canUpdate: Bool = false, reason: String? = nil,
        manager: String = "manual", source: String? = nil, phase: Phase = .idle,
        startedAt: Date? = nil, finishedAt: Date? = nil, log: String? = nil,
        obstacle: Obstacle? = nil, busy: Busy? = nil, waitingSince: Date? = nil,
        canRestart: Bool = false, automation: Automation? = nil, toolchain: String? = nil,
        job: Job? = nil, release: Release? = nil
    ) {
        self.job = job
        self.release = release
        self.obstacle = obstacle
        self.busy = busy
        self.waitingSince = waitingSince
        self.canRestart = canRestart
        self.automation = automation
        self.toolchain = toolchain
        self.version = version
        self.running = running
        self.restartRequired = restartRequired
        self.builtAt = builtAt
        self.remote = remote
        self.ahead = ahead
        self.commit = commit
        self.latestVersion = latestVersion
        self.latestCommit = latestCommit
        self.updateAvailable = updateAvailable
        self.behind = behind
        self.changes = changes
        self.canUpdate = canUpdate
        self.reason = reason
        self.manager = manager
        self.source = source
        self.phase = phase
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.log = log
    }

    /// True while the server is working through an update it accepted — including the stretch where
    /// it is restarting and answering nothing at all.
    public var isRunning: Bool {
        phase == .running || phase == .building || phase == .waiting || phase == .restarting
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
        running = try container.decodeIfPresent(String.self, forKey: .running)
        restartRequired =
            try container.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
        builtAt = try container.decodeIfPresent(Date.self, forKey: .builtAt)
        remote = try container.decodeIfPresent(RemoteCheck.self, forKey: .remote)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead)
        commit = try container.decodeIfPresent(String.self, forKey: .commit)
        latestVersion = try container.decodeIfPresent(String.self, forKey: .latestVersion)
        latestCommit = try container.decodeIfPresent(String.self, forKey: .latestCommit)
        updateAvailable =
            try container.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
        behind = try container.decodeIfPresent(Int.self, forKey: .behind)
        changes = try container.decodeIfPresent([String].self, forKey: .changes) ?? []
        canUpdate = try container.decodeIfPresent(Bool.self, forKey: .canUpdate) ?? false
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        manager = try container.decodeIfPresent(String.self, forKey: .manager) ?? "manual"
        source = try container.decodeIfPresent(String.self, forKey: .source)
        phase =
            (try container.decodeIfPresent(String.self, forKey: .phase)).flatMap(Phase.init(rawValue:))
            ?? .idle
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        log = try container.decodeIfPresent(String.self, forKey: .log)
        obstacle = try container.decodeIfPresent(Obstacle.self, forKey: .obstacle)
        busy = try container.decodeIfPresent(Busy.self, forKey: .busy)
        waitingSince = try container.decodeIfPresent(Date.self, forKey: .waitingSince)
        canRestart = try container.decodeIfPresent(Bool.self, forKey: .canRestart) ?? false
        automation = try container.decodeIfPresent(Automation.self, forKey: .automation)
        toolchain = try container.decodeIfPresent(String.self, forKey: .toolchain)
        job = (try? container.decodeIfPresent(Job.self, forKey: .job)) ?? nil
        release = (try? container.decodeIfPresent(Release.self, forKey: .release)) ?? nil
    }
}

/// A backend whose server can install its own updates.
///
/// Conformance is not the same as ability: an old server that has never heard of the route throws
/// ``AgentError/unsupported(_:)``, and a server that cannot update itself says so in
/// ``ServerUpdate/reason``.
public protocol SelfUpdatingBackend: CodingAgentBackend {
    /// The server's version and, unless `checkingRemote` is false, whether a newer one exists.
    /// Checking the remote costs the server a network round trip, so a client polling an update in
    /// flight should pass false.
    func updateStatus(checkingRemote: Bool) async throws -> ServerUpdate
    /// The same answer, with the project fetched now rather than from the machine's own recent
    /// fetch — what an explicit "Check now" means. A server too old to tell the two apart answers
    /// the ordinary question.
    func updateStatusFetchingNow() async throws -> ServerUpdate
    /// Asks the server to update itself. Returns as soon as the work has been handed off; the
    /// server will stop answering for a moment when it restarts.
    func startUpdate() async throws -> ServerUpdate
    /// Asks the server to load a build already sitting on its disk. No fetch and no rebuild — the
    /// machine waits until nothing is running on it and then hands itself to its supervisor.
    func restartServer() async throws -> ServerUpdate
    /// Turns unattended updating on or off *on the server*, which is where it belongs: a device-
    /// local flag would mean the machine only stays current while that device keeps asking.
    func setAutoUpdate(_ enabled: Bool) async throws -> ServerUpdate
}

extension SelfUpdatingBackend {
    public func updateStatusFetchingNow() async throws -> ServerUpdate {
        try await updateStatus(checkingRemote: true)
    }

    public func restartServer() async throws -> ServerUpdate {
        throw AgentError.unsupported("This server cannot restart itself.")
    }

    public func setAutoUpdate(_ enabled: Bool) async throws -> ServerUpdate {
        throw AgentError.unsupported("This server has no update policy to set.")
    }
}
