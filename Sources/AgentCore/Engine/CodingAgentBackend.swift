import Foundation

public struct BackendCapabilities: Sendable, Hashable {
    public var supportsFileBrowsing: Bool
    public var supportsDiffs: Bool
    public var supportsPermissions: Bool
    public var supportsMultipleSessions: Bool
    public var supportsModelSelection: Bool
    public var supportsAttachments: Bool
    public var supportsReasoningEffort: Bool
    public var supportsClearing: Bool
    public var supportsForking: Bool
    public var supportsAbort: Bool
    public var supportsSessionUsage: Bool
    /// Whether the backend can aggregate the whole account's ledger over a window
    /// (``CodingAgentBackend/usageAnalytics(days:)``) rather than only one session's spend.
    public var supportsUsageAnalytics: Bool
    public var supportsQuestions: Bool
    /// Whether answering a question is indistinguishable from sending its text as
    /// a prompt — true for an agent whose ask blocks on a tool result no client
    /// can write. A client should then route the answer through its ordinary send
    /// path, so it queues behind a running turn instead of being refused by it.
    public var answersQuestionsByMessage: Bool
    public var supportsRenaming: Bool
    public var supportsSubagents: Bool
    /// Whether the backend can list the slash commands it will resolve, so a client can offer them
    /// for completion instead of guessing.
    public var supportsCommands: Bool
    /// Whether the backend reports a standing ``SessionGoal`` for a session.
    public var supportsGoals: Bool
    /// Whether the backend can summarize a conversation into its own context
    /// (``AgentConversation/compact(instructions:)``) and reports the boundary it left behind as a
    /// ``Compaction`` part in the transcript.
    public var supportsCompaction: Bool
    /// Whether this backend stamps `completedAt` on finished assistant
    /// messages. When false, a message upsert with a nil `completedAt` says
    /// nothing about liveness, so the engine must not infer "running" from it
    /// — only explicit status events and live text deltas count.
    public var reportsMessageCompletion: Bool
    /// Whether the backend can search inside conversations it has stored, rather than only listing
    /// their titles. A chat list matches titles; this is what makes what was actually said — the
    /// answer, the diff, the command that worked — findable after it scrolls off.
    public var supportsTranscriptSearch: Bool

    public init(
        supportsFileBrowsing: Bool,
        supportsDiffs: Bool,
        supportsPermissions: Bool,
        supportsMultipleSessions: Bool,
        supportsModelSelection: Bool,
        supportsAttachments: Bool,
        supportsReasoningEffort: Bool = false,
        supportsClearing: Bool = false,
        supportsForking: Bool = false,
        supportsAbort: Bool = false,
        supportsSessionUsage: Bool = false,
        supportsUsageAnalytics: Bool = false,
        supportsQuestions: Bool = false,
        answersQuestionsByMessage: Bool = false,
        supportsRenaming: Bool = false,
        supportsSubagents: Bool = false,
        supportsCommands: Bool = false,
        supportsGoals: Bool = false,
        supportsCompaction: Bool = false,
        reportsMessageCompletion: Bool = true,
        supportsTranscriptSearch: Bool = false
    ) {
        self.supportsFileBrowsing = supportsFileBrowsing
        self.supportsDiffs = supportsDiffs
        self.supportsPermissions = supportsPermissions
        self.supportsMultipleSessions = supportsMultipleSessions
        self.supportsModelSelection = supportsModelSelection
        self.supportsAttachments = supportsAttachments
        self.supportsReasoningEffort = supportsReasoningEffort
        self.supportsClearing = supportsClearing
        self.supportsForking = supportsForking
        self.supportsAbort = supportsAbort
        self.supportsSessionUsage = supportsSessionUsage
        self.supportsUsageAnalytics = supportsUsageAnalytics
        self.supportsQuestions = supportsQuestions
        self.answersQuestionsByMessage = answersQuestionsByMessage
        self.supportsRenaming = supportsRenaming
        self.supportsSubagents = supportsSubagents
        self.supportsCommands = supportsCommands
        self.supportsGoals = supportsGoals
        self.supportsCompaction = supportsCompaction
        self.reportsMessageCompletion = reportsMessageCompletion
        self.supportsTranscriptSearch = supportsTranscriptSearch
    }
}

/// One place inside one conversation where the words were found.
public struct TranscriptMatch: Sendable, Hashable, Codable {
    /// Which register the words were in — prose, the model's reasoning, a tool's input (named by
    /// the tool), or what a tool answered. Looking for a shell command and looking for a sentence
    /// are different searches, and only the person doing it knows which one this was.
    public var kind: String
    public var role: MessageRole
    /// The words, with enough either side to recognise them by.
    public var text: String
    public var at: Date?

    public init(kind: String, role: MessageRole, text: String, at: Date? = nil) {
        self.kind = kind
        self.role = role
        self.text = text
        self.at = at
    }
}

/// One conversation the words were found in, and where in it they were.
public struct TranscriptSearchHit: Sendable, Hashable, Codable, Identifiable {
    public var sessionID: String
    public var title: String
    public var directory: String?
    public var updatedAt: Date
    public var matches: [TranscriptMatch]
    /// How many places matched in the whole conversation, which is usually more than are carried
    /// here — a result has to be able to say "and forty more in this one".
    public var total: Int

    public var id: String { sessionID }

    public init(
        sessionID: String, title: String, directory: String? = nil, updatedAt: Date,
        matches: [TranscriptMatch], total: Int
    ) {
        self.sessionID = sessionID
        self.title = title
        self.directory = directory
        self.updatedAt = updatedAt
        self.matches = matches
        self.total = total
    }
}

/// What one server had to say about a query.
public struct TranscriptSearchResult: Sendable, Hashable, Codable {
    public var hits: [TranscriptSearchHit]
    /// Conversations actually opened.
    public var scanned: Int
    /// Whether the server stopped before it had looked everywhere. A search that quietly gave up is
    /// worse than one that says so, because an absence then reads as an answer.
    public var truncated: Bool

    public init(hits: [TranscriptSearchHit], scanned: Int = 0, truncated: Bool = false) {
        self.hits = hits
        self.scanned = scanned
        self.truncated = truncated
    }
}

public struct AgentUsage: Sendable, Hashable, Codable {
    public var costUSD: Double?
    public var tokens: Int?

    public init(costUSD: Double? = nil, tokens: Int? = nil) {
        self.costUSD = costUSD
        self.tokens = tokens
    }
}

/// What a whole conversation has cost, turn by turn, as the backend can account for it.
///
/// A subscription bills a flat fee, so a backend that prices tokens against the metered API rates
/// says so with ``estimated`` and every surface repeats it: this is what the conversation would
/// have cost on the API, which is the only figure that makes two conversations comparable.
public struct SessionSpendReport: Sendable, Hashable, Codable {
    /// The token tiers that price differently — cache reads are an order of magnitude cheaper than
    /// fresh input, and cache writes cost more than either, which is most of why one conversation
    /// costs ten times another.
    public struct Tokens: Sendable, Hashable, Codable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var cacheWrite5m: Int
        public var cacheWrite1h: Int

        public init(
            input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite5m: Int = 0,
            cacheWrite1h: Int = 0
        ) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite5m = cacheWrite5m
            self.cacheWrite1h = cacheWrite1h
        }

        public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        public var total: Int { input + output + cacheRead + cacheWrite }
    }

    /// One prompt and everything the agent did answering it. It begins when the person pressed
    /// return, because the wait is part of what the turn was.
    public struct Turn: Sendable, Hashable, Codable {
        public var at: Date
        public var seconds: Double?
        public var model: String?
        public var calls: Int
        public var tokens: Tokens
        public var costUSD: Double
        public var prompt: String?

        public init(
            at: Date, seconds: Double? = nil, model: String? = nil, calls: Int = 1,
            tokens: Tokens = Tokens(), costUSD: Double = 0, prompt: String? = nil
        ) {
            self.at = at
            self.seconds = seconds
            self.model = model
            self.calls = calls
            self.tokens = tokens
            self.costUSD = costUSD
            self.prompt = prompt
        }
    }

    public struct ModelShare: Sendable, Hashable, Codable {
        public var model: String
        public var turns: Int
        public var tokens: Tokens
        public var costUSD: Double

        public init(model: String, turns: Int, tokens: Tokens, costUSD: Double) {
            self.model = model
            self.turns = turns
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    public var costUSD: Double
    public var tokens: Tokens
    public var turns: [Turn]
    public var byModel: [ModelShare]
    public var startedAt: Date?
    public var endedAt: Date?
    /// True when the money was priced from a rate table rather than reported by the provider.
    public var estimated: Bool

    public init(
        costUSD: Double, tokens: Tokens, turns: [Turn], byModel: [ModelShare],
        startedAt: Date? = nil, endedAt: Date? = nil, estimated: Bool = true
    ) {
        self.costUSD = costUSD
        self.tokens = tokens
        self.turns = turns
        self.byModel = byModel
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.estimated = estimated
    }
}

/// The whole account's ledger over a window of days, aggregated by the machine that holds the
/// transcripts: every session's turns bucketed by day, model, project and tool, with the records
/// worth bragging about. Everything a server can say about how it has been used, in one report.
///
/// Money follows ``SessionSpendReport``'s rules — API-equivalent value, marked ``estimated``,
/// never a bill.
public struct UsageAnalyticsReport: Sendable, Hashable, Codable {
    public typealias Tokens = SessionSpendReport.Tokens

    public struct Totals: Sendable, Hashable, Codable {
        public var costUSD: Double
        public var tokens: Tokens
        public var turns: Int
        public var toolCalls: Int
        public var sessions: Int
        public var activeDays: Int

        public init(
            costUSD: Double = 0, tokens: Tokens = Tokens(), turns: Int = 0, toolCalls: Int = 0,
            sessions: Int = 0, activeDays: Int = 0
        ) {
            self.costUSD = costUSD
            self.tokens = tokens
            self.turns = turns
            self.toolCalls = toolCalls
            self.sessions = sessions
            self.activeDays = activeDays
        }
    }

    /// One calendar day in the server's own timezone, keyed "yyyy-MM-dd" — the bucket boundary
    /// belongs to the machine where the work happened.
    public struct Day: Sendable, Hashable, Codable {
        public var day: String
        public var costUSD: Double
        public var tokens: Tokens
        public var turns: Int
        public var toolCalls: Int
        public var sessions: Int

        public init(
            day: String, costUSD: Double = 0, tokens: Tokens = Tokens(), turns: Int = 0,
            toolCalls: Int = 0, sessions: Int = 0
        ) {
            self.day = day
            self.costUSD = costUSD
            self.tokens = tokens
            self.turns = turns
            self.toolCalls = toolCalls
            self.sessions = sessions
        }
    }

    public struct Project: Sendable, Hashable, Codable {
        public var directory: String
        public var name: String
        public var sessions: Int
        public var turns: Int
        public var costUSD: Double
        public var tokens: Tokens

        public init(
            directory: String, name: String, sessions: Int = 0, turns: Int = 0,
            costUSD: Double = 0, tokens: Tokens = Tokens()
        ) {
            self.directory = directory
            self.name = name
            self.sessions = sessions
            self.turns = turns
            self.costUSD = costUSD
            self.tokens = tokens
        }
    }

    public struct Tool: Sendable, Hashable, Codable {
        public var name: String
        public var calls: Int

        public init(name: String, calls: Int) {
            self.name = name
            self.calls = calls
        }
    }

    public struct Compactions: Sendable, Hashable, Codable {
        public var count: Int
        public var reclaimedTokens: Int

        public init(count: Int = 0, reclaimedTokens: Int = 0) {
            self.count = count
            self.reclaimedTokens = reclaimedTokens
        }
    }

    public struct Subagents: Sendable, Hashable, Codable {
        public var runs: Int
        public var tokens: Tokens
        public var costUSD: Double

        public init(runs: Int = 0, tokens: Tokens = Tokens(), costUSD: Double = 0) {
            self.runs = runs
            self.tokens = tokens
            self.costUSD = costUSD
        }
    }

    public struct Records: Sendable, Hashable, Codable {
        public struct BusiestDay: Sendable, Hashable, Codable {
            public var day: String
            public var costUSD: Double
            public var turns: Int

            public init(day: String, costUSD: Double, turns: Int) {
                self.day = day
                self.costUSD = costUSD
                self.turns = turns
            }
        }

        public struct Session: Sendable, Hashable, Codable {
            public var id: String
            public var title: String
            public var costUSD: Double
            public var turns: Int

            public init(id: String, title: String, costUSD: Double, turns: Int) {
                self.id = id
                self.title = title
                self.costUSD = costUSD
                self.turns = turns
            }
        }

        public struct Turn: Sendable, Hashable, Codable {
            public var at: Date
            public var costUSD: Double
            public var seconds: Double?
            public var model: String?
            public var prompt: String?
            public var sessionTitle: String?

            public init(
                at: Date, costUSD: Double, seconds: Double? = nil, model: String? = nil,
                prompt: String? = nil, sessionTitle: String? = nil
            ) {
                self.at = at
                self.costUSD = costUSD
                self.seconds = seconds
                self.model = model
                self.prompt = prompt
                self.sessionTitle = sessionTitle
            }
        }

        public var busiestDay: BusiestDay?
        public var priciestSession: Session?
        public var priciestTurn: Turn?
        public var longestTurn: Turn?
        public var streakDays: Int

        public init(
            busiestDay: BusiestDay? = nil, priciestSession: Session? = nil,
            priciestTurn: Turn? = nil, longestTurn: Turn? = nil, streakDays: Int = 0
        ) {
            self.busiestDay = busiestDay
            self.priciestSession = priciestSession
            self.priciestTurn = priciestTurn
            self.longestTurn = longestTurn
            self.streakDays = streakDays
        }
    }

    public var since: Date
    public var generatedAt: Date
    public var days: Int
    public var estimated: Bool
    public var totals: Totals
    public var daily: [Day]
    public var models: [SessionSpendReport.ModelShare]
    public var projects: [Project]
    public var tools: [Tool]
    /// Turns begun in each hour of the server's day, index 0–23 — the account's clock.
    public var hourTurns: [Int]
    public var hourCostUSD: [Double]
    /// What the window's cache reads would have cost as fresh input, less what they cost as
    /// reads — the money caching kept in the person's pocket.
    public var cacheSavedUSD: Double
    public var compactions: Compactions
    public var subagents: Subagents
    public var records: Records

    public init(
        since: Date, generatedAt: Date, days: Int, estimated: Bool = true,
        totals: Totals = Totals(), daily: [Day] = [],
        models: [SessionSpendReport.ModelShare] = [], projects: [Project] = [],
        tools: [Tool] = [], hourTurns: [Int] = [], hourCostUSD: [Double] = [],
        cacheSavedUSD: Double = 0, compactions: Compactions = Compactions(),
        subagents: Subagents = Subagents(), records: Records = Records()
    ) {
        self.since = since
        self.generatedAt = generatedAt
        self.days = days
        self.estimated = estimated
        self.totals = totals
        self.daily = daily
        self.models = models
        self.projects = projects
        self.tools = tools
        self.hourTurns = hourTurns
        self.hourCostUSD = hourCostUSD
        self.cacheSavedUSD = cacheSavedUSD
        self.compactions = compactions
        self.subagents = subagents
        self.records = records
    }

    public var isEmpty: Bool { totals.turns == 0 && totals.costUSD <= 0 }
}

/// Live subscription quota for a provider (Claude Max/Pro rolling rate limits), sourced from the
/// provider's own usage API rather than estimated from message costs.
public struct UsageQuota: Sendable, Hashable, Codable {
    /// One rate-limit gauge in a provider's quota, ready to render as a progress bar.
    public struct Gauge: Sendable, Hashable, Codable {
        public var key: String
        public var label: String
        /// The *used* fraction of this quota window as reported by the provider: `0.0` is a fresh
        /// window, `1.0` is exhausted, and a bar bound to it fills as quota is consumed (do not
        /// invert). Normally within `0...1`, but the Kit passes the provider value through without
        /// clamping, so a value can momentarily read slightly above `1` when the provider counts an
        /// over-limit request — clamp at the presentation layer if a bar must not overflow.
        public var fraction: Double
        /// When the window is expected to reset, if known.
        public var resetsAt: Date?
        /// Whether ``resetsAt`` is a real provider-reported reset time rather than one the backend
        /// estimated locally. Show an exact countdown only when `true`; otherwise treat ``resetsAt``
        /// as approximate.
        public var trustedReset: Bool
        /// For spend-based windows, the money already used and the window's ceiling, when the
        /// provider reports them. A renderer can then say "$0.61 of $40" instead of "2%".
        public var usedUSD: Double?
        public var limitUSD: Double?

        public init(
            key: String, label: String, fraction: Double, resetsAt: Date?, trustedReset: Bool,
            usedUSD: Double? = nil, limitUSD: Double? = nil
        ) {
            self.key = key
            self.label = label
            self.fraction = fraction
            self.resetsAt = resetsAt
            self.trustedReset = trustedReset
            self.usedUSD = usedUSD
            self.limitUSD = limitUSD
        }
    }

    public struct Detail: Sendable, Hashable, Codable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var providerName: String
    public var subtitle: String
    public var source: String
    public var live: Bool
    public var gauges: [Gauge]
    public var details: [Detail]

    public init(
        providerName: String, subtitle: String, source: String, live: Bool,
        gauges: [Gauge], details: [Detail]
    ) {
        self.providerName = providerName
        self.subtitle = subtitle
        self.source = source
        self.live = live
        self.gauges = gauges
        self.details = details
    }
}

public struct ServerHealth: Sendable, Hashable {
    public var healthy: Bool
    public var version: String?

    public init(healthy: Bool, version: String? = nil) {
        self.healthy = healthy
        self.version = version
    }
}

public enum BackendStatus: String, Sendable, Hashable, Codable {
    case idle
    case running
    /// Render this exactly like ``idle`` (a settled turn). No current backend emits it — it is a
    /// leftover from the removed agentapi TUI-scraping transport (0.6.1) — but it stays a valid case
    /// so older cached ``ConversationState`` JSON that recorded it still decodes.
    case stable
    case unknown
}

public struct BackendFailure: Error, Sendable, Hashable, Codable {
    public var message: String
    public var code: String?
    public var retryable: Bool
    public var detail: String?

    public init(message: String, code: String? = nil, retryable: Bool = false, detail: String? = nil) {
        self.message = message
        self.code = code
        self.retryable = retryable
        self.detail = detail
    }
}

public struct PermissionRequest: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var sessionID: String
    public var title: String?
    public var toolName: String?

    public init(id: String, sessionID: String, title: String? = nil, toolName: String? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.toolName = toolName
    }
}

public enum PermissionDecision: String, Sendable {
    case once
    case always
    case reject
}

/// A structured question the agent asks mid-turn (opencode's question tool):
/// one request can carry several questions, each with predefined options,
/// optional multi-select, and optional free-form ("custom") answers.
public struct QuestionRequest: Sendable, Hashable, Codable, Identifiable {
    public struct Option: Sendable, Hashable, Codable {
        public let label: String
        public let description: String

        public init(label: String, description: String) {
            self.label = label
            self.description = description
        }
    }

    public struct Item: Sendable, Hashable, Codable {
        public let question: String
        public let header: String
        public let options: [Option]
        public let multiple: Bool
        public let custom: Bool

        public init(
            question: String, header: String, options: [Option],
            multiple: Bool = false, custom: Bool = false
        ) {
            self.question = question
            self.header = header
            self.options = options
            self.multiple = multiple
            self.custom = custom
        }
    }

    public let id: String
    public var sessionID: String
    public var questions: [Item]

    public init(id: String, sessionID: String, questions: [Item]) {
        self.id = id
        self.sessionID = sessionID
        self.questions = questions
    }
}

public enum BackendEvent: Sendable {
    case messageUpserted(ChatMessage, replaceParts: Bool)
    case partUpserted(messageID: String, MessagePart)
    case partTextDelta(messageID: String, partID: String, delta: String)
    case partRemoved(messageID: String, partID: String)
    case messageRemoved(messageID: String)
    case status(BackendStatus)
    /// The session's standing goal changed; `nil` once nothing is being pursued.
    case goal(SessionGoal?)
    /// A compaction started, finished (`nil`), or failed. Distinct from ``status`` because
    /// compaction runs *inside* a turn: the backend is still running, just not answering.
    case compaction(CompactionActivity?)
    case permission(PermissionRequest)
    /// An approval stopped being pending — answered here, on another device, or in the terminal.
    /// Without it a second client keeps a live approval card for a tool the first already allowed,
    /// and answering it posts a decision the server has no request for.
    case permissionResolved(requestID: String)
    case question(QuestionRequest)
    case questionResolved(requestID: String)
    case failure(BackendFailure)
    case unknown(type: String)
}

/// A coding-agent server behind one unified surface. Conformers translate their wire protocol
/// into ``BackendEvent`` values a ``MessageReducer`` folds.
public protocol CodingAgentBackend: Sendable {
    var agentType: AgentType { get }
    var capabilities: BackendCapabilities { get }

    func health() async throws -> ServerHealth
    func listSessions() async throws -> [AgentSession]
    /// Sessions across every worktree the server knows, not just its own — a
    /// session list that covers one project at a time would otherwise lose
    /// every chat that works elsewhere. `knownDirectories` are extra places
    /// the caller has seen sessions work in. Defaults to the plain listing.
    func listAllSessions(knownDirectories: [String]) async throws -> [AgentSession]
    /// Worktrees this server knows about, for backends whose session list covers
    /// only one at a time. Empty when the backend has no such notion.
    func projects() async throws -> [AgentProject]
    /// Sessions belonging to one worktree; `nil` means whatever the server
    /// considers its own.
    func listSessions(inWorktree worktree: String?) async throws -> [AgentSession]
    func createSession(title: String?, directory: String?) async throws -> AgentSession
    func deleteSession(_ sessionID: String) async throws
    func messages(for sessionID: String) async throws -> [ChatMessage]
    func send(_ prompt: SendPrompt, to sessionID: String) async throws
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error>
    func abort(sessionID: String) async throws
    func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    /// Answers a pending question request: one answer array per question, in
    /// order, each holding the selected option labels (or a custom string).
    func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws
    func rejectQuestion(_ request: QuestionRequest) async throws
    /// Questions currently blocking a turn — used to recover state after a
    /// reconnect, since the asked event is not replayed. Empty when
    /// unsupported.
    func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest]
    /// Questions readable straight out of a transcript the client already holds,
    /// for agents whose ask-the-user tool is an ordinary tool call awaiting its
    /// result rather than a side-channel request. Pure and synchronous, so a
    /// conversation can re-derive it on every structural update for free.
    func pendingQuestions(in messages: [ChatMessage], sessionID: String) -> [QuestionRequest]
    /// Bytes behind a file part the backend itself handed out, fetched over the
    /// same transport and credentials as the rest of the session — a client
    /// cannot open the server's URL on its own when it sits behind auth or a
    /// private overlay. Throws ``AgentError/unsupported(_:)`` by default.
    func attachmentData(_ file: FileReference) async throws -> Data
    func availableModels() async throws -> [ModelInfo]
    /// Named agent presets selectable per prompt via `SendPrompt.agent` (opencode exposes them at
    /// `GET /agent`). Defaults to empty and no shipped backend overrides it yet, so an agent picker
    /// has nothing to list — pass known `SendPrompt.agent` names out of band until discovery lands.
    func availableAgents() async throws -> [String]
    func defaultModel() async throws -> ModelSelection?

    /// Reasoning-effort levels a conformer accepts as `SendPrompt.reasoningEffort` (Claude Code:
    /// low/medium/high/xhigh/max). Empty if the backend has no effort control.
    var reasoningEffortOptions: [String] { get }
    /// Applies a reasoning-effort level as a standing, out-of-band session setting — for a backend
    /// that keeps effort server-side rather than reading it per message. The current backends take
    /// effort per prompt via `SendPrompt.reasoningEffort` instead, so none override this and the
    /// default throws ``AgentError/unsupported(_:)``; prefer the per-send parameter.
    func setReasoningEffort(_ level: String) async throws
    /// Applies a model selection as a standing, out-of-band session setting — for a backend that
    /// persists the model server-side rather than reading it per message. The current backends take
    /// the model per prompt via `SendPrompt.model` instead, so none override this and the default
    /// throws ``AgentError/unsupported(_:)``; prefer the per-send parameter.
    func applyModelSelection(_ model: ModelSelection) async throws
    /// Clears the conversation in place (Claude Code sends a `/clear` control command) for backends
    /// that keep a single long-lived session rather than discrete ones.
    func clearConversation(_ sessionID: String) async throws
    /// The last turn's cost/token usage for a session, if the backend reports it.
    func sessionUsage(_ sessionID: String) async throws -> AgentUsage?
    /// Everything the backend can account for about what this conversation has cost, turn by turn.
    /// `nil` when the backend cannot say — the client then falls back to whatever the transcript it
    /// already holds can be made to admit.
    func sessionSpend(_ sessionID: String) async throws -> SessionSpendReport?
    /// The whole account's ledger over the last `days` days, aggregated across every session the
    /// backend's machine holds. `nil` when the backend cannot say — a server too old for the
    /// route is one that cannot answer, never one that spent nothing.
    func usageAnalytics(days: Int) async throws -> UsageAnalyticsReport?
    /// Live subscription quota (rolling rate-limit gauges) for the whole account, if the backend
    /// exposes a usage API. `nil` when unsupported.
    func usageQuota() async throws -> UsageQuota?
    /// Registers an ActivityKit push token so the server can drive Live
    /// Activity updates over APNs while the app is suspended. No-op for
    /// backends without push infrastructure.
    func registerLiveActivity(_ registration: LiveActivityRegistration, for sessionID: String) async throws
    /// Registers the app's APNs device token server-wide, so the backend can push
    /// turn-completion alerts and silent usage refreshes while the app is
    /// suspended. No-op for backends without push infrastructure.
    func registerDeviceToken(_ registration: DevicePushRegistration) async throws
    /// Removes a previously registered APNs device token, so a server the app no
    /// longer knows stops pushing to it. No-op for backends without push
    /// infrastructure.
    func unregisterDeviceToken(_ registration: DevicePushRegistration) async throws
    /// Live quotas for other providers the backend's host machine is signed into (the bridge
    /// serves Grok's billing quota alongside Claude's). Empty when unsupported.
    func additionalUsageQuotas() async throws -> [UsageQuota]
    /// Branches a session into a new one seeded with the same history, so the next prompt explores a
    /// different direction without disturbing the original (Claude Code resumes with `--fork-session`).
    func forkSession(_ sessionID: String) async throws -> AgentSession
    /// Renames a session's display title.
    func renameSession(_ sessionID: String, title: String) async throws
    /// Slash commands this server will resolve — built-ins plus whatever the machine and the given
    /// worktree contribute. Empty when the backend can't enumerate them.
    func availableCommands(directory: String?) async throws -> [AgentCommand]
    /// Runs a slash command in a session. Backends with a dedicated command API use it; the rest
    /// fall back to sending `/name arguments` as prompt text, which is how a CLI-backed agent
    /// resolves commands anyway.
    func runCommand(_ command: AgentCommand, arguments: String?, in sessionID: String) async throws
    /// Whether running a command is indistinguishable from sending its text as a prompt. When true
    /// a client can route commands through its ordinary send path — echoing the typed command into
    /// the transcript and showing the turn start — instead of firing a side-channel request whose
    /// effect only appears once the server streams it back.
    var resolvesCommandsFromPromptText: Bool { get }
    /// The session's standing goal, if the backend tracks one.
    func goal(for sessionID: String) async throws -> SessionGoal?
    /// Subagents spawned within a session (Claude Code sidecar transcripts). Empty when unsupported.
    func subagents(for sessionID: String) async throws -> [SubagentSummary]
    /// A subagent's full transcript, rendered in the same message model as the session itself.
    func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage]
    /// Searches inside every conversation this server has stored — what was said, what was
    /// reasoned, what was run and what it answered — rather than only their titles. Throws
    /// ``AgentError/unsupported(_:)`` by default; check ``BackendCapabilities/supportsTranscriptSearch``
    /// before offering it, and treat a server that lacks it as one that cannot answer rather than
    /// one that found nothing.
    func searchTranscripts(_ query: String, limit: Int) async throws -> TranscriptSearchResult
}

extension CodingAgentBackend {
    public func abort(sessionID: String) async throws {
        throw AgentError.unsupported("abort")
    }

    public func respond(to permission: PermissionRequest, decision: PermissionDecision) async throws
    {
        throw AgentError.unsupported("permissions")
    }

    public func answerQuestion(_ request: QuestionRequest, answers: [[String]]) async throws {
        throw AgentError.unsupported("questions")
    }

    public func rejectQuestion(_ request: QuestionRequest) async throws {
        throw AgentError.unsupported("questions")
    }

    public func pendingQuestions(for sessionID: String) async throws -> [QuestionRequest] { [] }

    public func pendingQuestions(
        in messages: [ChatMessage], sessionID: String
    ) -> [QuestionRequest] { [] }

    public func deleteSession(_ sessionID: String) async throws {
        throw AgentError.unsupported("deleteSession")
    }

    public func availableModels() async throws -> [ModelInfo] { [] }
    public func availableAgents() async throws -> [String] { [] }
    public func defaultModel() async throws -> ModelSelection? { nil }

    public var reasoningEffortOptions: [String] { [] }
    public func setReasoningEffort(_ level: String) async throws {
        throw AgentError.unsupported("reasoningEffort")
    }
    public func applyModelSelection(_ model: ModelSelection) async throws {
        throw AgentError.unsupported("modelSelection")
    }
    public func clearConversation(_ sessionID: String) async throws {
        throw AgentError.unsupported("clearConversation")
    }
    public func projects() async throws -> [AgentProject] { [] }

    public func listAllSessions(knownDirectories: [String]) async throws -> [AgentSession] {
        try await listSessions()
    }

    public func listSessions(inWorktree worktree: String?) async throws -> [AgentSession] {
        try await listSessions()
    }

    public func sessionUsage(_ sessionID: String) async throws -> AgentUsage? { nil }
    public func sessionSpend(_ sessionID: String) async throws -> SessionSpendReport? { nil }
    public func usageAnalytics(days: Int) async throws -> UsageAnalyticsReport? { nil }
    public func usageQuota() async throws -> UsageQuota? { nil }
    public func additionalUsageQuotas() async throws -> [UsageQuota] { [] }
    public func forkSession(_ sessionID: String) async throws -> AgentSession {
        throw AgentError.unsupported("fork")
    }

    public func renameSession(_ sessionID: String, title: String) async throws {
        throw AgentError.unsupported("rename")
    }

    public func availableCommands(directory: String?) async throws -> [AgentCommand] { [] }

    /// Prompt text is the universal fallback: an agent CLI resolves `/name args` from a plain
    /// prompt, so a backend only needs to override this if it has a first-class command endpoint.
    public func runCommand(
        _ command: AgentCommand, arguments: String?, in sessionID: String
    ) async throws {
        try await send(SendPrompt(text: command.invocation(arguments: arguments)), to: sessionID)
    }

    public var resolvesCommandsFromPromptText: Bool { true }

    public func goal(for sessionID: String) async throws -> SessionGoal? { nil }

    public func subagents(for sessionID: String) async throws -> [SubagentSummary] { [] }

    public func attachmentData(_ file: FileReference) async throws -> Data {
        throw AgentError.unsupported("attachments")
    }

    public func searchTranscripts(_ query: String, limit: Int) async throws
        -> TranscriptSearchResult
    {
        throw AgentError.unsupported("search")
    }

    public func subagentMessages(sessionID: String, agentID: String) async throws -> [ChatMessage] {
        throw AgentError.unsupported("subagents")
    }
}

public protocol FileBrowsingBackend: CodingAgentBackend {
    func listFiles(path: String?) async throws -> [FileNode]
    func fileContent(path: String) async throws -> String
    func diff(sessionID: String) async throws -> [FileDiff]
    func find(pattern: String) async throws -> [String]
    func providers() async throws -> [Provider]
}
