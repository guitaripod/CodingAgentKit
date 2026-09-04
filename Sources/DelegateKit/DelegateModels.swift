import Foundation

/// How hard a worker is asked to think; maps onto the runner's own effort setting.
public enum DelegateEffort: String, Codable, Sendable, Hashable, CaseIterable {
    case low, medium, high
}

/// The dispatch posture for a run: the defaults, one rung cheaper with a gate before the top, or one rung dearer.
public enum DelegateMode: String, Codable, Sendable, Hashable, CaseIterable {
    case normal, conserve, rush
}

public enum DelegateRunStatus: String, Codable, Sendable, Hashable {
    case running, passed, failed, held, cancelled, error

    public var isSettled: Bool { self != .running }
}

public enum DelegateAttemptStatus: String, Codable, Sendable, Hashable {
    case pass, fail, timeout, scope, error
}

/// One delegated unit of work exactly as the daemon stores it.
public struct DelegatePacket: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var taskClass: String
    public var goal: String
    public var paths: [String]
    public var verify: String?
    public var read: [String]
    public var notes: String?
    public var tier: String?
    public var ceiling: String?
    public var effort: DelegateEffort?
    public var timeout: Int?
    public var attempts: Int?
    public var mode: DelegateMode?
    public var repo: String?
    public var created: String?

    enum CodingKeys: String, CodingKey {
        case id, goal, paths, verify, read, notes, tier, ceiling, effort, timeout, attempts, mode, repo, created
        case taskClass = "class"
    }

    public init(
        id: String, taskClass: String, goal: String, paths: [String] = [], verify: String? = nil,
        read: [String] = [], notes: String? = nil, tier: String? = nil, ceiling: String? = nil,
        effort: DelegateEffort? = nil, timeout: Int? = nil, attempts: Int? = nil,
        mode: DelegateMode? = nil, repo: String? = nil, created: String? = nil
    ) {
        self.id = id
        self.taskClass = taskClass
        self.goal = goal
        self.paths = paths
        self.verify = verify
        self.read = read
        self.notes = notes
        self.tier = tier
        self.ceiling = ceiling
        self.effort = effort
        self.timeout = timeout
        self.attempts = attempts
        self.mode = mode
        self.repo = repo
        self.created = created
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taskClass = try c.decode(String.self, forKey: .taskClass)
        goal = try c.decode(String.self, forKey: .goal)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        verify = try c.decodeIfPresent(String.self, forKey: .verify)
        read = try c.decodeIfPresent([String].self, forKey: .read) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        ceiling = try c.decodeIfPresent(String.self, forKey: .ceiling)
        effort = try c.decodeIfPresent(DelegateEffort.self, forKey: .effort)
        timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts)
        mode = try c.decodeIfPresent(DelegateMode.self, forKey: .mode)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        created = try c.decodeIfPresent(String.self, forKey: .created)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(taskClass, forKey: .taskClass)
        try c.encode(goal, forKey: .goal)
        if !paths.isEmpty { try c.encode(paths, forKey: .paths) }
        try c.encodeIfPresent(verify, forKey: .verify)
        if !read.isEmpty { try c.encode(read, forKey: .read) }
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(tier, forKey: .tier)
        try c.encodeIfPresent(ceiling, forKey: .ceiling)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(timeout, forKey: .timeout)
        try c.encodeIfPresent(attempts, forKey: .attempts)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(created, forKey: .created)
    }

    /// A fresh packet with a daemon-compatible ULID-shaped id minted on this device.
    public static func draft(taskClass: String, goal: String, repo: String?) -> DelegatePacket {
        DelegatePacket(
            id: DelegateIdentifier.mint(), taskClass: taskClass, goal: goal, repo: repo,
            created: DelegateTimestamp.format(Date()))
    }
}

/// Per-run overrides a caller may send beside a packet.
public struct DelegateOverrides: Codable, Sendable, Hashable {
    public var tier: String?
    public var ceiling: String?
    public var mode: DelegateMode?
    public var attempts: Int?

    public init(tier: String? = nil, ceiling: String? = nil, mode: DelegateMode? = nil, attempts: Int? = nil) {
        self.tier = tier
        self.ceiling = ceiling
        self.mode = mode
        self.attempts = attempts
    }

    public var isEmpty: Bool { tier == nil && ceiling == nil && mode == nil && attempts == nil }
}

public struct DelegateRun: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var packetID: String
    public var taskClass: String
    public var repo: String
    public var host: String
    public var mode: DelegateMode
    public var startTier: String
    public var ceiling: String
    public var status: DelegateRunStatus
    public var createdAt: String
    public var finishedAt: String?
    public var passedTier: String?
    public var escalations: Int
    public var summary: String
    public var packet: DelegatePacket

    enum CodingKeys: String, CodingKey {
        case id, repo, host, mode, ceiling, status, escalations, summary, packet
        case packetID = "packet_id"
        case taskClass = "class"
        case startTier = "start_tier"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case passedTier = "passed_tier"
    }

    public var created: Date? { DelegateTimestamp.parse(createdAt) }
    public var finished: Date? { finishedAt.flatMap(DelegateTimestamp.parse) }

    public init(
        id: String, packetID: String, taskClass: String, repo: String, host: String, mode: DelegateMode,
        startTier: String, ceiling: String, status: DelegateRunStatus, createdAt: String,
        finishedAt: String? = nil, passedTier: String? = nil, escalations: Int = 0, summary: String = "",
        packet: DelegatePacket
    ) {
        self.id = id
        self.packetID = packetID
        self.taskClass = taskClass
        self.repo = repo
        self.host = host
        self.mode = mode
        self.startTier = startTier
        self.ceiling = ceiling
        self.status = status
        self.createdAt = createdAt
        self.finishedAt = finishedAt
        self.passedTier = passedTier
        self.escalations = escalations
        self.summary = summary
        self.packet = packet
    }
}

public struct DelegateAttempt: Codable, Sendable, Hashable {
    public var runID: String
    public var tier: String
    public var chainIndex: Int
    public var runner: String
    public var model: String
    public var attempt: Int
    public var status: DelegateAttemptStatus
    public var verifyExit: Int?
    public var durationMS: Int
    public var tokensIn: Int
    public var tokensOut: Int
    public var changedFiles: [String]
    public var scopeViolations: [String]
    public var verifyTail: String
    public var workerSummary: String
    public var startedAt: String
    public var finishedAt: String

    enum CodingKeys: String, CodingKey {
        case tier, runner, model, attempt, status
        case runID = "run_id"
        case chainIndex = "chain_index"
        case verifyExit = "verify_exit"
        case durationMS = "duration_ms"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case changedFiles = "changed_files"
        case scopeViolations = "scope_violations"
        case verifyTail = "verify_tail"
        case workerSummary = "worker_summary"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    public var duration: Duration { .milliseconds(durationMS) }

    public init(
        runID: String, tier: String, chainIndex: Int, runner: String, model: String, attempt: Int,
        status: DelegateAttemptStatus, verifyExit: Int? = nil, durationMS: Int, tokensIn: Int = 0,
        tokensOut: Int = 0, changedFiles: [String] = [], scopeViolations: [String] = [],
        verifyTail: String = "", workerSummary: String = "", startedAt: String = "", finishedAt: String = ""
    ) {
        self.runID = runID
        self.tier = tier
        self.chainIndex = chainIndex
        self.runner = runner
        self.model = model
        self.attempt = attempt
        self.status = status
        self.verifyExit = verifyExit
        self.durationMS = durationMS
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.changedFiles = changedFiles
        self.scopeViolations = scopeViolations
        self.verifyTail = verifyTail
        self.workerSummary = workerSummary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

public struct DelegateRunDetail: Codable, Sendable, Hashable {
    public var run: DelegateRun
    public var attempts: [DelegateAttempt]
    public var live: Bool

    public init(run: DelegateRun, attempts: [DelegateAttempt], live: Bool) {
        self.run = run
        self.attempts = attempts
        self.live = live
    }
}

public struct DelegateStat: Codable, Sendable, Hashable {
    public var taskClass: String
    public var tier: String
    public var attempts: Int
    public var passes: Int
    public var passRate: Double
    public var averageMS: Double
    public var tokensIn: Int
    public var tokensOut: Int

    enum CodingKeys: String, CodingKey {
        case tier, attempts, passes
        case taskClass = "class"
        case passRate = "pass_rate"
        case averageMS = "avg_ms"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
    }

    public init(
        taskClass: String, tier: String, attempts: Int, passes: Int, passRate: Double, averageMS: Double,
        tokensIn: Int, tokensOut: Int
    ) {
        self.taskClass = taskClass
        self.tier = tier
        self.attempts = attempts
        self.passes = passes
        self.passRate = passRate
        self.averageMS = averageMS
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
    }
}

public struct DelegateChainEntry: Codable, Sendable, Hashable {
    public var runner: String
    public var model: String
    public var thinking: String?
    public var health: String?
    public var healthy: Bool?
    public var reason: String?

    public init(runner: String, model: String, thinking: String? = nil, health: String? = nil, healthy: Bool? = nil, reason: String? = nil) {
        self.runner = runner
        self.model = model
        self.thinking = thinking
        self.health = health
        self.healthy = healthy
        self.reason = reason
    }
}

public struct DelegateTier: Codable, Sendable, Hashable, Identifiable {
    public var tier: String
    public var label: String
    public var chain: [DelegateChainEntry]

    public var id: String { tier }

    public init(tier: String, label: String, chain: [DelegateChainEntry]) {
        self.tier = tier
        self.label = label
        self.chain = chain
    }

    /// The entry a run on this host would use right now, or nil when every probed entry is down.
    public var activeEntry: DelegateChainEntry? {
        chain.first { $0.healthy != false }
    }
}

public struct DelegateCapabilities: Codable, Sendable, Hashable {
    public var api: Int
    public var version: String
    public var host: String
    public var features: [String]
    public var tiers: [String]
    public var classes: [String]
    public var modes: [String]

    public init(api: Int, version: String, host: String, features: [String], tiers: [String], classes: [String], modes: [String]) {
        self.api = api
        self.version = version
        self.host = host
        self.features = features
        self.tiers = tiers
        self.classes = classes
        self.modes = modes
    }
}

public struct DelegateHealth: Codable, Sendable, Hashable {
    public var ok: Bool
    public var version: String

    public init(ok: Bool, version: String) {
        self.ok = ok
        self.version = version
    }
}

/// One line of a run's story, as the daemon emits it over SSE and stores it in its log.
public enum DelegateEvent: Sendable, Hashable {
    case runStarted(packetID: String, taskClass: String, startTier: String, ceiling: String, mode: DelegateMode, host: String, repo: String)
    case tierSelected(tier: String, label: String, runner: String, model: String, chainIndex: Int)
    case tierSkipped(tier: String, reason: String)
    case attemptStarted(tier: String, attempt: Int, model: String)
    case progress(tier: String, attempt: Int, text: String)
    case attemptFinished(DelegateAttemptOutcome)
    case approvalRequired(tier: String, reason: String)
    case approvalResolved(tier: String, approved: Bool)
    case escalated(from: String, to: String, reason: String)
    case chainFailover(tier: String, from: String, to: String, reason: String)
    case applied(files: [String], patchBytes: Int)
    case runFinished(status: DelegateRunStatus, passedTier: String?, escalations: Int, durationMS: Int, summary: String)
    case unknown(kind: String)

    public var isTerminal: Bool {
        if case .runFinished = self { return true }
        return false
    }
}

public struct DelegateAttemptOutcome: Sendable, Hashable {
    public var tier: String
    public var attempt: Int
    public var status: DelegateAttemptStatus
    public var verifyExit: Int?
    public var durationMS: Int
    public var tokensIn: Int
    public var tokensOut: Int
    public var changedFiles: [String]
    public var scopeViolations: [String]
    public var verifyTail: String
    public var workerSummary: String

    public init(
        tier: String, attempt: Int, status: DelegateAttemptStatus, verifyExit: Int? = nil,
        durationMS: Int, tokensIn: Int = 0, tokensOut: Int = 0, changedFiles: [String] = [],
        scopeViolations: [String] = [], verifyTail: String = "", workerSummary: String = ""
    ) {
        self.tier = tier
        self.attempt = attempt
        self.status = status
        self.verifyExit = verifyExit
        self.durationMS = durationMS
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.changedFiles = changedFiles
        self.scopeViolations = scopeViolations
        self.verifyTail = verifyTail
        self.workerSummary = workerSummary
    }
}

/// An event with its place in the run: the run it belongs to, its sequence number, and when it happened.
public struct DelegateEnvelope: Sendable, Hashable, Identifiable {
    public var runID: String
    public var seq: Int
    public var timestamp: String
    public var event: DelegateEvent

    public var id: String { "\(runID):\(seq)" }
    public var date: Date? { DelegateTimestamp.parse(timestamp) }

    public init(runID: String, seq: Int, timestamp: String, event: DelegateEvent) {
        self.runID = runID
        self.seq = seq
        self.timestamp = timestamp
        self.event = event
    }
}

extension DelegateEnvelope: Decodable {
    private enum Keys: String, CodingKey {
        case runID = "run_id"
        case seq, ts, kind
        case packetID = "packet_id"
        case taskClass = "class"
        case startTier = "start_tier"
        case ceiling, mode, host, repo, tier, label, runner, model, reason, attempt, text, status, approved, from, to, files, summary
        case chainIndex = "chain_index"
        case verifyExit = "verify_exit"
        case durationMS = "duration_ms"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case changedFiles = "changed_files"
        case scopeViolations = "scope_violations"
        case verifyTail = "verify_tail"
        case workerSummary = "worker_summary"
        case patchBytes = "patch_bytes"
        case passedTier = "passed_tier"
        case escalations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        runID = try c.decode(String.self, forKey: .runID)
        seq = try c.decode(Int.self, forKey: .seq)
        timestamp = try c.decode(String.self, forKey: .ts)
        let kind = try c.decode(String.self, forKey: .kind)
        event = try Self.decodeEvent(kind: kind, from: c)
    }

    private static func decodeEvent(kind: String, from c: KeyedDecodingContainer<Keys>) throws -> DelegateEvent {
        switch kind {
        case "run_started":
            return .runStarted(
                packetID: try c.decode(String.self, forKey: .packetID),
                taskClass: try c.decode(String.self, forKey: .taskClass),
                startTier: try c.decode(String.self, forKey: .startTier),
                ceiling: try c.decode(String.self, forKey: .ceiling),
                mode: try c.decodeIfPresent(DelegateMode.self, forKey: .mode) ?? .normal,
                host: try c.decodeIfPresent(String.self, forKey: .host) ?? "",
                repo: try c.decodeIfPresent(String.self, forKey: .repo) ?? "")
        case "tier_selected":
            return .tierSelected(
                tier: try c.decode(String.self, forKey: .tier),
                label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                runner: try c.decodeIfPresent(String.self, forKey: .runner) ?? "",
                model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
                chainIndex: try c.decodeIfPresent(Int.self, forKey: .chainIndex) ?? 0)
        case "tier_skipped":
            return .tierSkipped(
                tier: try c.decode(String.self, forKey: .tier),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "attempt_started":
            return .attemptStarted(
                tier: try c.decode(String.self, forKey: .tier),
                attempt: try c.decode(Int.self, forKey: .attempt),
                model: try c.decodeIfPresent(String.self, forKey: .model) ?? "")
        case "progress":
            return .progress(
                tier: try c.decode(String.self, forKey: .tier),
                attempt: try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0,
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "attempt_finished":
            return .attemptFinished(
                DelegateAttemptOutcome(
                    tier: try c.decode(String.self, forKey: .tier),
                    attempt: try c.decode(Int.self, forKey: .attempt),
                    status: try c.decode(DelegateAttemptStatus.self, forKey: .status),
                    verifyExit: try c.decodeIfPresent(Int.self, forKey: .verifyExit),
                    durationMS: try c.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0,
                    tokensIn: try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0,
                    tokensOut: try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0,
                    changedFiles: try c.decodeIfPresent([String].self, forKey: .changedFiles) ?? [],
                    scopeViolations: try c.decodeIfPresent([String].self, forKey: .scopeViolations) ?? [],
                    verifyTail: try c.decodeIfPresent(String.self, forKey: .verifyTail) ?? "",
                    workerSummary: try c.decodeIfPresent(String.self, forKey: .workerSummary) ?? ""))
        case "approval_required":
            return .approvalRequired(
                tier: try c.decode(String.self, forKey: .tier),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "approval_resolved":
            return .approvalResolved(
                tier: try c.decode(String.self, forKey: .tier),
                approved: try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false)
        case "escalated":
            return .escalated(
                from: try c.decode(String.self, forKey: .from),
                to: try c.decode(String.self, forKey: .to),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "chain_failover":
            return .chainFailover(
                tier: try c.decode(String.self, forKey: .tier),
                from: try c.decode(String.self, forKey: .from),
                to: try c.decode(String.self, forKey: .to),
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
        case "applied":
            return .applied(
                files: try c.decodeIfPresent([String].self, forKey: .files) ?? [],
                patchBytes: try c.decodeIfPresent(Int.self, forKey: .patchBytes) ?? 0)
        case "run_finished":
            return .runFinished(
                status: try c.decode(DelegateRunStatus.self, forKey: .status),
                passedTier: try c.decodeIfPresent(String.self, forKey: .passedTier),
                escalations: try c.decodeIfPresent(Int.self, forKey: .escalations) ?? 0,
                durationMS: try c.decodeIfPresent(Int.self, forKey: .durationMS) ?? 0,
                summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "")
        default:
            return .unknown(kind: kind)
        }
    }
}

/// The daemon stamps RFC 3339 with nanoseconds; Foundation's parser wants milliseconds at most.
public enum DelegateTimestamp {
    public static func parse(_ text: String) -> Date? {
        let trimmed = trimFraction(text)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    public static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func trimFraction(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        let afterDot = text.index(after: dot)
        var end = afterDot
        while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
        let digits = text[afterDot..<end]
        if digits.count <= 3 { return text }
        return String(text[..<afterDot]) + digits.prefix(3) + String(text[end...])
    }
}

/// ULID-shaped identifiers (Crockford base32, time-ordered) so packets minted on a phone sort beside the daemon's.
public enum DelegateIdentifier {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func mint(now: Date = Date()) -> String {
        var value = UInt64(now.timeIntervalSince1970 * 1000)
        var time = [Character](repeating: "0", count: 10)
        for i in stride(from: 9, through: 0, by: -1) {
            time[i] = alphabet[Int(value & 31)]
            value >>= 5
        }
        let random = (0..<16).map { _ in alphabet[Int.random(in: 0..<32)] }
        return String(time + random)
    }
}
