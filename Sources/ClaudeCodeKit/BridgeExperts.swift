import AgentCore
import Foundation

private struct BRExpertDraftRequest: Encodable {
    let session: String?
    let skill: String?
}

private struct BRGuardRun: Encodable {
    let guardID: String?

    private enum CodingKeys: String, CodingKey {
        case guardID = "guard"
    }
}

private struct BRTaskStarted: Decodable {
    let session: BRSummary
    let queued: Int?
}

extension ClaudeCodeBackend: MachineExperts {
    public func machineExperts() async throws -> [MachineExpert]? {
        guard agentType == .claudeCode else { return nil }
        do {
            let data = try await http.send(builder.request(.get, "/experts"))
            return try BridgeCoding.decoder.decode([BRLenient<MachineExpert>].self, from: data).compactMap(\.value)
        } catch AgentError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public func machineExpert(_ id: String, prove: Bool) async throws -> MachineExpert {
        let query = prove ? [URLQueryItem(name: "prove", value: "1")] : []
        let data = try await http.send(builder.request(.get, "/experts/\(Self.expertPath(id))", query: query))
        return try BridgeCoding.decoder.decode(MachineExpert.self, from: data)
    }

    public func createExpert(_ draft: ExpertDraft) async throws -> MachineExpert {
        let body = try BridgeCoding.encoder.encode(draft)
        let data = try await http.send(builder.request(.post, "/experts", body: body))
        return try BridgeCoding.decoder.decode(MachineExpert.self, from: data)
    }

    public func updateExpert(_ id: String, _ change: ExpertChange) async throws -> MachineExpert {
        let body = try BridgeCoding.encoder.encode(change)
        let data = try await http.send(builder.request(.patch, "/experts/\(Self.expertPath(id))", body: body))
        return try BridgeCoding.decoder.decode(MachineExpert.self, from: data)
    }

    public func deleteExpert(_ id: String) async throws {
        _ = try await http.send(builder.request(.delete, "/experts/\(Self.expertPath(id))"))
    }

    public func draftExpert(session: String?, skill: String?) async throws -> ExpertDraft {
        let body = try BridgeCoding.encoder.encode(BRExpertDraftRequest(session: session, skill: skill))
        let data = try await http.send(builder.request(.post, "/experts/draft", body: body))
        return try BridgeCoding.decoder.decode(ExpertDraft.self, from: data)
    }

    public func expertSkills() async throws -> [ExpertSkill] {
        let data = try await http.send(builder.request(.get, "/experts/skills"))
        return try BridgeCoding.decoder.decode([BRLenient<ExpertSkill>].self, from: data).compactMap(\.value)
    }

    public func expertNotes(_ id: String, retired: Bool) async throws -> [ExpertNote] {
        let query = retired ? [URLQueryItem(name: "retired", value: "1")] : []
        let data = try await http.send(
            builder.request(.get, "/experts/\(Self.expertPath(id))/notebook", query: query))
        return try BridgeCoding.decoder.decode([BRLenient<ExpertNote>].self, from: data).compactMap(\.value)
    }

    public func expertNote(_ id: String, note: String) async throws -> ExpertNote {
        let data = try await http.send(
            builder.request(.get, "/experts/\(Self.expertPath(id))/notebook/\(Self.expertPath(note))"))
        return try BridgeCoding.decoder.decode(ExpertNote.self, from: data)
    }

    public func expertJournal(_ id: String) async throws -> [ExpertJournalEntry] {
        let data = try await http.send(builder.request(.get, "/experts/\(Self.expertPath(id))/journal"))
        return try BridgeCoding.decoder.decode([BRLenient<ExpertJournalEntry>].self, from: data).compactMap(\.value)
    }

    public func expertBrief(_ id: String) async throws -> ExpertBriefPreview {
        let data = try await http.send(builder.request(.get, "/experts/\(Self.expertPath(id))/brief"))
        return try BridgeCoding.decoder.decode(ExpertBriefPreview.self, from: data)
    }

    public func runExpertGuards(_ id: String, guardID: String?) async throws -> MachineExpert {
        let body = try BridgeCoding.encoder.encode(BRGuardRun(guardID: guardID))
        let data = try await http.send(
            builder.request(.post, "/experts/\(Self.expertPath(id))/guards/run", body: body))
        return try BridgeCoding.decoder.decode(MachineExpert.self, from: data)
    }

    public func startExpertTask(_ id: String, _ request: ExpertTaskRequest) async throws -> ExpertTaskStarted {
        let body = try BridgeCoding.encoder.encode(request)
        let data = try await http.send(builder.request(.post, "/experts/\(Self.expertPath(id))/tasks", body: body))
        let started = try BridgeCoding.decoder.decode(BRTaskStarted.self, from: data)
        return ExpertTaskStarted(session: started.session.session(agentType: agentType), queued: started.queued)
    }

    public func expertDebrief(sessionID: String) async throws -> ExpertDebrief? {
        do {
            let data = try await http.send(
                builder.request(.get, "/sessions/\(Self.expertPath(sessionID))/debrief"))
            return try BridgeCoding.decoder.decode(ExpertDebrief.self, from: data)
        } catch AgentError.http(let status, _) where status == 404 {
            return nil
        }
    }

    public func finishExpertTask(sessionID: String) async throws -> ExpertDebrief {
        let data = try await http.send(builder.request(.post, "/sessions/\(Self.expertPath(sessionID))/debrief"))
        return try BridgeCoding.decoder.decode(ExpertDebrief.self, from: data)
    }

    public func decideExpertDebrief(sessionID: String, _ decision: ExpertDebriefDecision) async throws
        -> ExpertDebrief
    {
        let body = try BridgeCoding.encoder.encode(decision)
        let data = try await http.send(
            builder.request(.post, "/sessions/\(Self.expertPath(sessionID))/debrief/accept", body: body))
        return try BridgeCoding.decoder.decode(ExpertDebrief.self, from: data)
    }

    private static func expertPath(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? id
    }
}
