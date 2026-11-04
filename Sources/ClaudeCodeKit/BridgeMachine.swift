import AgentCore
import Foundation

/// What a bridge says it keeps besides conversations — schedules, other agents — and the agents
/// whose models it lists, learned from `/status` and `/agents/models` and remembered per server
/// for the whole process the way the queue's support is.
final class BridgeMachineFacts: @unchecked Sendable {
    private let lock = NSLock()
    private var schedules = false
    private var agents = false
    private var agentIDs: Set<String> = []
    private var agentNames: [String: String] = [:]

    var keepsSchedules: Bool { lock.withLock { schedules } }
    var hostsAgents: Bool { lock.withLock { agents } }

    func record(schedules: Bool, agents: Bool) {
        lock.withLock {
            self.schedules = schedules
            self.agents = agents
        }
    }

    func record(agentModels rows: [BRAgentModel]) {
        lock.withLock {
            agentIDs = Set(rows.map(\.provider))
            agentNames = Dictionary(rows.map { ($0.provider, $0.providerName) }) { first, _ in first }
        }
    }

    func isAgent(_ providerID: String) -> Bool { lock.withLock { agentIDs.contains(providerID) } }

    func agentName(_ providerID: String) -> String? { lock.withLock { agentNames[providerID] } }
}

enum BridgeMachineRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var facts: [String: BridgeMachineFacts] = [:]

    static func facts(config: ServerConfig, agentType: AgentType) -> BridgeMachineFacts {
        let key = config.baseURL.absoluteString + "|" + agentType.rawValue + "|"
            + (config.credentials?.username ?? "") + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = facts[key] { return existing }
            let created = BridgeMachineFacts()
            facts[key] = created
            return created
        }
    }
}

/// One row of claude-bridge's `/agents/models`.
struct BRAgentModel: Decodable {
    let id: String
    let name: String
    let provider: String
    let providerName: String
    let variants: [String]?
    let contextWindow: Int?
}

private struct BRAgentKey: Encodable {
    let env: String
    let value: String
}

private struct BRAgentID: Encodable {
    let id: String
}

private struct BRSignInStart: Encodable {
    let method: String
}

private struct BRSignInInput: Encodable {
    let text: String
}

extension ClaudeCodeBackend: MachineScheduling {
    public func machineSchedules() async throws -> [MachineSchedule]? {
        do {
            let data = try await http.send(builder.request(.get, "/schedules"))
            return try BridgeCoding.decoder.decode([BRLenient<MachineSchedule>].self, from: data)
                .compactMap(\.value)
        } catch AgentError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public func createSchedule(_ draft: ScheduleDraft) async throws -> MachineSchedule {
        let body = try BridgeCoding.encoder.encode(draft)
        let data = try await http.send(builder.request(.post, "/schedules", body: body))
        return try BridgeCoding.decoder.decode(MachineSchedule.self, from: data)
    }

    public func updateSchedule(_ id: String, _ change: ScheduleChange) async throws -> MachineSchedule {
        let body = try BridgeCoding.encoder.encode(change)
        let data = try await http.send(builder.request(.patch, "/schedules/\(id)", body: body))
        return try BridgeCoding.decoder.decode(MachineSchedule.self, from: data)
    }

    public func deleteSchedule(_ id: String) async throws {
        _ = try await http.send(builder.request(.delete, "/schedules/\(id)"))
    }

    public func runSchedule(_ id: String) async throws -> MachineSchedule {
        let data = try await http.send(builder.request(.post, "/schedules/\(id)/run"))
        return try BridgeCoding.decoder.decode(MachineSchedule.self, from: data)
    }
}

extension ClaudeCodeBackend: MachineAgentHosting {
    public func machineAgents(refreshBrains: Bool) async throws -> MachineAgentsReport? {
        do {
            let query = refreshBrains ? [URLQueryItem(name: "refresh", value: "1")] : []
            let data = try await http.send(builder.request(.get, "/agents", query: query))
            return try BridgeCoding.decoder.decode(MachineAgentsReport.self, from: data)
        } catch AgentError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public func agentRegistry() async throws -> [RegistryAgent] {
        let data = try await http.send(builder.request(.get, "/agents/registry"))
        return try BridgeCoding.decoder.decode([BRLenient<RegistryAgent>].self, from: data)
            .compactMap(\.value)
    }

    public func addAgent(_ id: String) async throws -> MachineAgent {
        try await agentPress(.post, "/agents/\(Self.escaped(id))/add")
    }

    public func removeAgent(_ id: String) async throws {
        _ = try await http.send(builder.request(.post, "/agents/\(Self.escaped(id))/remove"))
    }

    public func checkAgent(_ id: String) async throws -> MachineAgent {
        try await agentPress(.post, "/agents/\(Self.escaped(id))/check")
    }

    public func installAgent(_ id: String) async throws -> MachineAgent {
        try await agentPress(.post, "/agents/install", body: try BridgeCoding.encoder.encode(BRAgentID(id: id)))
    }

    public func setAgentKey(_ id: String, env: String, value: String) async throws -> MachineAgent {
        try await agentPress(
            .post, "/agents/\(Self.escaped(id))/key",
            body: try BridgeCoding.encoder.encode(BRAgentKey(env: env, value: value)))
    }

    public func setAgentBrain(_ id: String, _ choice: AgentBrainChoice) async throws -> MachineAgent {
        try await agentPress(
            .post, "/agents/\(Self.escaped(id))/brain", body: try BridgeCoding.encoder.encode(choice))
    }

    public func startAgentSignIn(_ id: String, method: String) async throws -> AgentSignInRelay {
        let data = try await http.send(
            builder.request(
                .post, "/agents/\(Self.escaped(id))/signin",
                body: try BridgeCoding.encoder.encode(BRSignInStart(method: method))))
        return try BridgeCoding.decoder.decode(AgentSignInRelay.self, from: data)
    }

    public func agentSignIn(_ id: String) async throws -> AgentSignInRelay? {
        do {
            let data = try await http.send(builder.request(.get, "/agents/\(Self.escaped(id))/signin"))
            return try BridgeCoding.decoder.decode(AgentSignInRelay.self, from: data)
        } catch AgentError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public func sendAgentSignIn(_ id: String, text: String) async throws {
        _ = try await http.send(
            builder.request(
                .post, "/agents/\(Self.escaped(id))/signin/input",
                body: try BridgeCoding.encoder.encode(BRSignInInput(text: text))))
    }

    public func cancelAgentSignIn(_ id: String) async throws {
        _ = try await http.send(builder.request(.post, "/agents/\(Self.escaped(id))/signin/cancel"))
    }

    /// The models every agent this bridge hosts offers, as a catalog lists them: the agent's id is
    /// the provider, its name rides on each model. Learned once per catalog read so a send knows
    /// which provider ids are agents.
    func agentModels() async -> [ModelInfo] {
        guard let data = try? await http.send(builder.request(.get, "/agents/models")),
            let rows = try? BridgeCoding.decoder.decode([BRAgentModel].self, from: data)
        else { return [] }
        machineFacts.record(agentModels: rows)
        return rows.map { row in
            ModelInfo(
                id: row.id, name: row.name, providerID: row.provider,
                variants: row.variants, contextWindow: row.contextWindow, agentName: row.providerName)
        }
    }

    private func agentPress(_ method: HTTPMethod, _ path: String, body: Data? = nil) async throws
        -> MachineAgent
    {
        let data = try await http.send(builder.request(method, path, body: body))
        return try BridgeCoding.decoder.decode(MachineAgent.self, from: data)
    }

    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? id
    }
}

/// claude-bridge measures a Claude conversation's window by asking its CLI. omp-bridge has no
/// such question, so an omp backend never asks.
extension ClaudeCodeBackend: ContextMeasuring {
    public func measuredContext(for sessionID: String) async throws -> MeasuredContext? {
        guard agentType == .claudeCode else { return nil }
        let data: Data
        do {
            data = try await http.send(builder.request(.get, "/sessions/\(sessionID)/context"))
        } catch AgentError.http(let status, _) where status == 404 {
            return nil
        }
        return try BridgeCoding.decoder.decode(MeasuredContext.self, from: data)
    }
}
