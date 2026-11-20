import AgentCore
import Foundation

/// The experts a mock machine keeps, with their notebooks, journals and debriefs.
public struct MockExperts: Sendable {
    public var experts: [MachineExpert]
    public var notes: [String: [ExpertNote]]
    public var journals: [String: [ExpertJournalEntry]]
    public var debriefs: [String: ExpertDebrief]
    public var skills: [ExpertSkill]

    public init(
        experts: [MachineExpert], notes: [String: [ExpertNote]] = [:], journals: [String: [ExpertJournalEntry]] = [:],
        debriefs: [String: ExpertDebrief] = [:], skills: [ExpertSkill] = []
    ) {
        self.experts = experts
        self.notes = notes
        self.journals = journals
        self.debriefs = debriefs
        self.skills = skills
    }
}

extension MockBackend: MachineExperts {
    public func machineExperts() async throws -> [MachineExpert]? {
        withMachine { state in state.machineExperts.map { $0.map { Self.served($0, in: state) } } }
    }

    public func machineExpert(_ id: String, prove: Bool) async throws -> MachineExpert {
        try withMachine { state in
            guard let expert = state.machineExperts?.first(where: { $0.id == id }) else { throw Self.noExpert }
            return Self.served(expert, in: state)
        }
    }

    public func createExpert(_ draft: ExpertDraft) async throws -> MachineExpert {
        try withMachine { state in
            guard state.machineExperts != nil else { throw AgentError.unsupported("experts") }
            let id = UUID().uuidString
            let expert = MachineExpert(
                id: id, name: draft.name, glyph: draft.glyph ?? String(draft.name.prefix(2)),
                hue: draft.hue ?? "blue", purpose: draft.purpose ?? "", directory: draft.directory,
                model: draft.model, effort: draft.effort, charter: draft.charter ?? "", skills: draft.skills ?? [],
                notebookPath: draft.notebookPath, bench: draft.bench ?? [], guards: draft.guards ?? [],
                guardRule: draft.guardRule)
            state.machineExperts?.append(expert)
            state.expertNotes[id] = (draft.notes ?? []).filter { $0.lasting != false }.map {
                ExpertNote(
                    id: "\($0.title.lowercased().replacingOccurrences(of: " ", with: "-")).md", title: $0.title,
                    summary: $0.summary, body: $0.body, written: Date())
            }
            return Self.served(expert, in: state)
        }
    }

    public func updateExpert(_ id: String, _ change: ExpertChange) async throws -> MachineExpert {
        try withMachine { state in
            guard let index = state.machineExperts?.firstIndex(where: { $0.id == id }),
                var expert = state.machineExperts?[index]
            else { throw Self.noExpert }
            if let name = change.name { expert.name = name }
            if let glyph = change.glyph { expert.glyph = glyph }
            if let hue = change.hue { expert.hue = hue }
            if let purpose = change.purpose { expert.purpose = purpose }
            if let directory = change.directory { expert.directory = directory.isEmpty ? nil : directory }
            if let model = change.model { expert.model = model.isEmpty ? nil : model }
            if let effort = change.effort { expert.effort = effort.isEmpty ? nil : effort }
            if let charter = change.charter { expert.charter = charter }
            if let skills = change.skills { expert.skills = skills }
            if let path = change.notebookPath { expert.notebookPath = path.isEmpty ? nil : path }
            if let bench = change.bench { expert.bench = bench }
            if let guards = change.guards { expert.guards = guards }
            if change.guardsOnDemand == true { expert.guardRule = nil } else if let rule = change.guardRule { expert.guardRule = rule }
            expert.updatedAt = Date()
            state.machineExperts?[index] = expert
            return Self.served(expert, in: state)
        }
    }

    public func deleteExpert(_ id: String) async throws {
        withMachine { $0.machineExperts?.removeAll { $0.id == id } }
    }

    public func draftExpert(session: String?, skill: String?) async throws -> ExpertDraft {
        ExpertDraft(
            name: skill.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "iPadOS", glyph: "iP", hue: "blue",
            purpose: "Makes the apps excellent on iPad, measured on the real iPads.",
            charter: "Make every app excellent on iPad at every window size and in both orientations. Measure on the real iPads before believing the simulator.",
            skills: [skill ?? "ipados"],
            bench: [ExpertBenchItem(name: "iPad Pro M1", kind: .appleDevice, identifier: "00008103-0019349C0ED0801E", lock: "/tmp/ipad-pro-m1.lock")],
            notes: [
                ExpertDraftNote(title: "The test devices", summary: "iPad Pro sideways, mini upright", body: "…"),
                ExpertDraftNote(
                    title: "Two thumbs, held sideways", summary: "Navigation left, the main action right", body: "…"),
                ExpertDraftNote(
                    title: "Port 8795 is taken by another agent", summary: "Use another port", body: "…",
                    lasting: false),
            ])
    }

    public func expertSkills() async throws -> [ExpertSkill] { withMachine { $0.expertSkills } }

    public func expertNotes(_ id: String, retired: Bool) async throws -> [ExpertNote] {
        withMachine { state in (state.expertNotes[id] ?? []).filter { ($0.retired != nil) == retired } }
    }

    public func expertNote(_ id: String, note: String) async throws -> ExpertNote {
        try withMachine { state in
            guard let found = state.expertNotes[id]?.first(where: { $0.id == note }) else {
                throw AgentError.http(status: 404, body: "There is no such note.")
            }
            return found
        }
    }

    public func expertJournal(_ id: String) async throws -> [ExpertJournalEntry] {
        withMachine { $0.expertJournals[id] ?? [] }
    }

    public func expertBrief(_ id: String) async throws -> ExpertBriefPreview {
        try withMachine { state in
            guard let expert = state.machineExperts?.first(where: { $0.id == id }) else { throw Self.noExpert }
            let text = "You are working as \"\(expert.name)\".\n\n## Charter\n\(expert.charter)"
            return ExpertBriefPreview(text: text, tokens: max(expert.briefTokens, text.count / 4))
        }
    }

    public func runExpertGuards(_ id: String, guardID: String?) async throws -> MachineExpert {
        try withMachine { state in
            guard let index = state.machineExperts?.firstIndex(where: { $0.id == id }),
                var expert = state.machineExperts?[index]
            else { throw Self.noExpert }
            for guardIndex in expert.guards.indices where guardID == nil || expert.guards[guardIndex].id == guardID {
                let run = ExpertGuardRun(at: Date(), passed: true, seconds: 12)
                expert.guards[guardIndex].last = run
                expert.guards[guardIndex].history = [run] + (expert.guards[guardIndex].history ?? [])
            }
            state.machineExperts?[index] = expert
            return Self.served(expert, in: state)
        }
    }

    public func startExpertTask(_ id: String, _ request: ExpertTaskRequest) async throws -> ExpertTaskStarted {
        let session: AgentSession = try withMachine { state in
            guard state.machineExperts?.contains(where: { $0.id == id }) == true else { throw Self.noExpert }
            state.mintCounter += 1
            let session = AgentSession(
                id: "mock-task-\(state.mintCounter)", agentType: agentType,
                title: request.title ?? String(request.text.prefix(48)), directory: request.directory,
                createdAt: Date(), updatedAt: Date(), isActive: true, expertID: id)
            state.sessions.insert(session, at: 0)
            return session
        }
        try await send(SendPrompt(text: request.text), to: session.id)
        return ExpertTaskStarted(session: session)
    }

    public func expertDebrief(sessionID: String) async throws -> ExpertDebrief? {
        withMachine { $0.expertDebriefs[sessionID] }
    }

    public func finishExpertTask(sessionID: String) async throws -> ExpertDebrief {
        try withMachine { state in
            guard let session = state.sessions.first(where: { $0.id == sessionID }), let expertID = session.expertID
            else { throw AgentError.http(status: 404, body: "That conversation is not one of this machine's expert tasks.") }
            let journal = ExpertJournalEntry(
                sessionID: sessionID, title: session.title, at: Date(),
                outcome: "Posts zoom out of their card and close by any back gesture; swiping right always goes back.",
                measured: ["280 tests"], commits: ["2508baa fix(ios): a rightward swipe always goes back"])
            let existing = state.expertNotes[expertID] ?? []
            var proposals = [
                ExpertProposal(
                    op: .add, title: "Open things the platform’s way",
                    summary: "Push or zoom from the card, never a side column with its own ✕",
                    body: "Open from a grid by zooming out of the tapped card.\n**Why:** it is how the platform opens things.\n**How to apply:** start from UIKit's own transitions.",
                    reason: "This task replaced the side column with the zoom."),
                ExpertProposal(
                    op: .add, title: "Swiping right on a pushed page is Back",
                    summary: "Rows there carry no leading swipe actions",
                    body: "…", reason: "Swiping back over a post liked it."),
            ]
            if let old = existing.first(where: { $0.retired == nil && $0.title.contains("column") }) {
                proposals.append(
                    ExpertProposal(
                        op: .retire, note: old.id, title: old.title, summary: old.summary, body: "",
                        reason: "Replaced today by the zoom from the card."))
            }
            let debrief = ExpertDebrief(
                sessionID: sessionID, expertID: expertID, at: Date(), coveredTurns: 1, state: .open,
                journal: journal, proposals: proposals)
            state.expertDebriefs[sessionID] = debrief
            state.expertJournals[expertID, default: []].insert(journal, at: 0)
            return debrief
        }
    }

    public func decideExpertDebrief(sessionID: String, _ decision: ExpertDebriefDecision) async throws
        -> ExpertDebrief
    {
        try withMachine { state in
            guard var debrief = state.expertDebriefs[sessionID], debrief.state == .open else {
                throw AgentError.http(status: 422, body: "This debrief has nothing waiting.")
            }
            let accepted = Set(decision.accepted)
            let skipped = Set(decision.skipped ?? [])
            for index in debrief.proposals.indices where debrief.proposals[index].state == .pending {
                var proposal = debrief.proposals[index]
                if let edit = decision.edits?[proposal.id] {
                    if let title = edit.title { proposal.title = title }
                    if let summary = edit.summary { proposal.summary = summary }
                    if let body = edit.body { proposal.body = body }
                }
                if accepted.contains(proposal.id) {
                    proposal.state = .accepted
                    switch proposal.op {
                    case .add:
                        state.expertNotes[debrief.expertID, default: []].insert(
                            ExpertNote(
                                id: "\(proposal.title.lowercased().replacingOccurrences(of: " ", with: "-")).md",
                                title: proposal.title, summary: proposal.summary, body: proposal.body, written: Date(),
                                source: "tailscode-expert:\(debrief.expertID):\(sessionID)"),
                            at: 0)
                    case .change:
                        if let noteIndex = state.expertNotes[debrief.expertID]?.firstIndex(where: { $0.id == proposal.note }) {
                            state.expertNotes[debrief.expertID]?[noteIndex].title = proposal.title
                            state.expertNotes[debrief.expertID]?[noteIndex].summary = proposal.summary
                            state.expertNotes[debrief.expertID]?[noteIndex].confirmed = Date()
                        }
                    case .retire:
                        if let noteIndex = state.expertNotes[debrief.expertID]?.firstIndex(where: { $0.id == proposal.note }) {
                            state.expertNotes[debrief.expertID]?[noteIndex].retired = ExpertNoteRetirement(
                                at: Date(), reason: proposal.reason)
                        }
                    }
                } else if skipped.contains(proposal.id) || decision.skipped == nil {
                    proposal.state = .skipped
                }
                debrief.proposals[index] = proposal
            }
            if !debrief.proposals.contains(where: { $0.state == .pending }) { debrief.state = .settled }
            state.expertDebriefs[sessionID] = debrief
            return debrief
        }
    }

    private static var noExpert: AgentError { AgentError.http(status: 404, body: "There is no such expert on this machine.") }

    /// The expert with what the machine knows about it now: its notebook counted, its tasks and
    /// the proposals waiting, read off the mock's own state.
    static func served(_ expert: MachineExpert, in state: Mutable) -> MachineExpert {
        var served = expert
        let notes = state.expertNotes[expert.id] ?? []
        let live = notes.filter { $0.retired == nil }
        served.notebook = ExpertNotebookFacts(
            path: expert.notebookPath ?? "~/.claude-bridge/experts/\(expert.id)/notebook",
            adopted: expert.notebookPath != nil, notes: live.count, stale: live.filter(\.stale).count,
            retired: notes.count - live.count)
        let tasks = state.sessions.filter { $0.expertID == expert.id }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map {
                ExpertTaskRef(
                    sessionID: $0.id, title: $0.title, updatedAt: $0.updatedAt, active: $0.isActive == true,
                    debrief: state.expertDebriefs[$0.id]?.state)
            }
        if !tasks.isEmpty {
            served.tasks = Array(tasks.prefix(10))
            served.task = tasks.first { $0.active }
        }
        let journal = state.expertJournals[expert.id] ?? []
        if !journal.isEmpty { served.journal = Array(journal.prefix(5)) }
        let debriefs = state.expertDebriefs.values.filter { $0.expertID == expert.id }
        if !debriefs.isEmpty || expert.pending == 0 {
            served.pending = debriefs.reduce(0) { $0 + $1.pending.count }
        }
        return served
    }
}
