import AgentCore
import Foundation

extension MockBackend: MachineScheduling {
    public func machineSchedules() async throws -> [MachineSchedule]? {
        withMachine { $0.machineSchedules }
    }

    public func createSchedule(_ draft: ScheduleDraft) async throws -> MachineSchedule {
        try withMachine { state in
            guard state.machineSchedules != nil else { throw AgentError.unsupported("schedules") }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = draft.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            let made = MachineSchedule(
                id: UUID().uuidString, text: draft.text,
                title: draft.title ?? String(draft.text.prefix(48)), model: draft.model,
                effort: draft.effort, directory: draft.directory, rule: draft.rule,
                timeZone: calendar.timeZone.identifier,
                next: draft.rule.next(after: Date(), calendar: calendar),
                thread: draft.thread ?? .continue, quiet: draft.quiet ?? draft.rule.isRepeating,
                sessionID: draft.sessionID, createdAt: Date(), createdBy: draft.createdBy)
            state.machineSchedules?.append(made)
            return made
        }
    }

    public func updateSchedule(_ id: String, _ change: ScheduleChange) async throws -> MachineSchedule {
        try withMachine { state in
            guard let index = state.machineSchedules?.firstIndex(where: { $0.id == id }),
                var schedule = state.machineSchedules?[index]
            else { throw AgentError.http(status: 404, body: "no such schedule") }
            if let text = change.text { schedule.text = text }
            if let title = change.title { schedule.title = title }
            if let model = change.model { schedule.model = model }
            if let effort = change.effort { schedule.effort = effort }
            if let paused = change.paused { schedule.paused = paused }
            if let thread = change.thread { schedule.thread = thread }
            if let quiet = change.quiet { schedule.quiet = quiet }
            if let rule = change.rule {
                schedule.rule = rule
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: schedule.timeZone) ?? .current
                schedule.next = rule.next(after: Date(), calendar: calendar)
            }
            state.machineSchedules?[index] = schedule
            return schedule
        }
    }

    public func deleteSchedule(_ id: String) async throws {
        withMachine { $0.machineSchedules?.removeAll { $0.id == id } }
    }

    public func runSchedule(_ id: String) async throws -> MachineSchedule {
        try withMachine { state in
            guard let index = state.machineSchedules?.firstIndex(where: { $0.id == id }),
                var schedule = state.machineSchedules?[index]
            else { throw AgentError.http(status: 404, body: "no such schedule") }
            schedule.runs.insert(
                ScheduleRun(
                    id: UUID().uuidString, scheduledFor: Date(), startedAt: Date(), endedAt: Date(),
                    sessionID: schedule.sessionID, outcome: .answered),
                at: 0)
            state.machineSchedules?[index] = schedule
            return schedule
        }
    }
}

extension MockBackend: MachineAgentHosting {
    public func machineAgents(refreshBrains: Bool) async throws -> MachineAgentsReport? {
        withMachine { $0.machineAgents }
    }

    public func agentRegistry() async throws -> [RegistryAgent] { agentRegistry }

    public func addAgent(_ id: String) async throws -> MachineAgent {
        try settle(id) { agent in
            agent.added = true
            if agent.state == .notAdded { agent.state = agent.models.isEmpty ? .needsBrain : .ready }
        }
    }

    public func removeAgent(_ id: String) async throws {
        _ = try? settle(id) { agent in
            agent.added = false
            agent.state = .notAdded
        }
    }

    public func checkAgent(_ id: String) async throws -> MachineAgent {
        try settle(id) { _ in }
    }

    public func installAgent(_ id: String) async throws -> MachineAgent {
        if withMachine({ $0.machineAgents?.agents.contains { $0.id == id } }) != true,
            let entry = agentRegistry.first(where: { $0.id == id })
        {
            withMachine {
                $0.machineAgents?.agents.append(
                    MachineAgent(
                        id: entry.id, name: entry.name, version: entry.version,
                        description: entry.description, icon: entry.icon, source: "installed",
                        added: true, state: .ready,
                        models: [MachineAgent.Choice(id: "default", name: entry.name)],
                        distribution: entry.distribution))
            }
        }
        return try settle(id) { $0.added = true }
    }

    public func setAgentKey(_ id: String, env: String, value: String) async throws -> MachineAgent {
        try settle(id) { agent in
            agent.keys = agent.keys.map { key in
                var kept = key
                if key.env == env { kept.set = true }
                return kept
            }
            agent.added = true
            agent.state = .ready
            if agent.models.isEmpty { agent.models = [MachineAgent.Choice(id: "default", name: agent.name)] }
        }
    }

    public func setAgentBrain(_ id: String, _ choice: AgentBrainChoice) async throws -> MachineAgent {
        let brains = withMachine { $0.machineAgents?.brains ?? [] }
        return try settle(id) { agent in
            let server = brains.first { $0.id == choice.brain } ?? brains.first
            agent.brain = MachineAgent.Brain(
                kind: choice.kind, name: choice.kind == "local" ? (server?.name ?? "local") : (choice.provider ?? "key"),
                baseURL: server?.baseURL, model: choice.model, provider: choice.provider)
            if choice.kind == "local", let server {
                agent.models = server.models.map { MachineAgent.Choice(id: "custom:\($0.id)", name: $0.name) }
                agent.currentModel = choice.model.map { "custom:\($0)" }
            }
            agent.added = true
            agent.state = .ready
        }
    }

    public func startAgentSignIn(_ id: String, method: String) async throws -> AgentSignInRelay {
        let relay = AgentSignInRelay(
            agent: id, method: method, state: .running,
            lines: ["Open this link to sign in:", "https://example.com/device", "and enter the code ABCD-1234"],
            links: ["https://example.com/device"], codes: ["ABCD-1234"])
        withMachine { $0.signIns[id] = relay }
        return relay
    }

    public func agentSignIn(_ id: String) async throws -> AgentSignInRelay? {
        withMachine { $0.signIns[id] }
    }

    public func sendAgentSignIn(_ id: String, text: String) async throws {
        withMachine { $0.signIns[id]?.state = .succeeded }
        _ = try? settle(id) { agent in
            agent.state = .ready
            agent.added = true
        }
    }

    public func cancelAgentSignIn(_ id: String) async throws {
        withMachine { $0.signIns[id]?.state = .cancelled }
    }

    private func settle(_ id: String, _ change: (inout MachineAgent) -> Void) throws -> MachineAgent {
        try withMachine { state in
            guard let index = state.machineAgents?.agents.firstIndex(where: { $0.id == id }),
                var agent = state.machineAgents?.agents[index]
            else { throw AgentError.http(status: 422, body: "no such agent") }
            change(&agent)
            agent.checkedAt = Date()
            state.machineAgents?.agents[index] = agent
            return agent
        }
    }
}
