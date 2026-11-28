import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

/// The schedule and agent payloads exactly as claude-bridge 1.17 served them on a live machine
/// running Hermes on a local llama-swap.
@Suite struct MachineWireTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try BridgeCoding.decoder.decode(type, from: Data(json.utf8))
    }

    private static let schedules = """
        [{"createdAt": "2026-11-02T19:02:30Z", "title": "What is the current uptime of this machine?\\u2026", "id": "50D5FC6B-4C6D-4C99-B055-B4C1E6D7B7A8", "createdBy": "curl", "quiet": true, "runs": [{"sessionID": "6908E02A-474E-4662-8C18-C2886BB9B3A7", "startedAt": "2026-11-02T19:02:38Z", "outcome": "quiet", "missed": 0, "scheduledFor": "2026-11-02T19:02:38Z", "endedAt": "2026-11-02T19:02:42Z", "id": "E61CA0AE-F27D-4F9F-936B-2E3DBC795B54"}, {"sessionID": "6908E02A-474E-4662-8C18-C2886BB9B3A7", "startedAt": "2026-11-02T19:02:30Z", "outcome": "caughtUp", "ending": "answered", "missed": 2, "failure": "off", "scheduledFor": "2026-11-02T19:02:30Z", "endedAt": "2026-11-02T19:02:37Z", "id": "90F0D87F-13EF-4AF7-A920-FF05F1FF5F27"}], "paused": false, "next": "2026-11-03T05:30:00Z", "timeZone": "Europe/Helsinki", "thread": "continue", "rule": {"hour": 7, "kind": "daily", "minute": 30}, "text": "What is the current uptime of this machine? Answer in one short line.", "sessionID": "6908E02A-474E-4662-8C18-C2886BB9B3A7", "model": "hermes/custom:nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf"}]
        """

    private static let agents = """
        {"agents": [{"version": "0.19.0", "brain": {"model": "nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf", "kind": "local", "name": "llama-swap", "baseURL": "http://127.0.0.1:8081/v1"}, "source": "available", "distribution": "uvx", "website": "https://hermes-agent.nousresearch.com", "brainStyle": "hermes", "state": "ready", "currentModel": "custom:nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf", "signIn": [{"kind": "agent", "id": "custom", "name": "custom runtime credentials"}, {"kind": "terminal", "id": "hermes-setup", "name": "Configure Hermes provider"}], "id": "hermes", "name": "Hermes", "efforts": [], "keys": [], "models": [{"id": "custom:flint", "name": "Flint", "description": "Provider: Custom endpoint"}, {"id": "custom:groot-19b-a3b-nvfp4", "name": "Groot"}], "added": true, "checkedAt": "2026-11-02T19:01:25Z"}, {"source": "found", "distribution": "download", "state": "notAdded", "signIn": [], "icon": "https://cdn.agentclientprotocol.com/registry/v1/latest/opencode.svg", "id": "opencode", "name": "OpenCode", "efforts": [], "models": [], "added": false, "keys": []}, {"id": "future", "name": "Future", "source": "found", "added": true, "state": "somethingNew"}], "brains": [{"id": "llama-swap", "name": "llama-swap", "models": [{"id": "flint", "name": "Flint"}], "baseURL": "http://127.0.0.1:8081/v1"}]}
        """

    /// Antigravity as claude-bridge 1.41 lists it on a machine where it is signed out.
    private static let antigravity = """
        {"agents":[{"name":"Antigravity","distribution":"download","checkedAt":"2026-11-28T05:18:30Z","description":"Google's coding agent on Gemini, with your Google AI plan or a Gemini API key.","source":"found","website":"https://antigravity.google","id":"antigravity-acp","icon":"https://cdn.agentclientprotocol.com/registry/v1/latest/antigravity-acp.svg","state":"needsSignIn","models":[],"keys":[{"name":"Gemini API key","url":"https://aistudio.google.com/apikey","alternative":true,"env":"GEMINI_API_KEY","set":false}],"added":true,"signIn":[{"name":"Log in with Google","kind":"agent","description":"Log in with your Google account","id":"oauth-personal"},{"name":"Log in with Gemini Enterprise","kind":"agent","description":"Log in with your Gemini Enterprise account","id":"oauth-business"},{"name":"Gemini API key","kind":"agent","description":"Use an API key with Gemini Developer API","id":"gemini-api-key"},{"name":"Gemini Enterprise Agent Platform","kind":"agent","description":"Use Gemini Enterprise Agent Platform (formerly Vertex AI) with Application Default Credentials","id":"agent-platform"},{"name":"Log in from the terminal","kind":"terminal","description":"Log in with your Google account by pasting a code in a terminal; works over SSH","id":"terminal-login"}],"failure":"Authentication required","version":"1.5.18","efforts":[]}],"brains":[]}
        """

    @Test func anAgentSignedInItsOwnWayOffersItsKeyAsAnotherWay() throws {
        let report = try decode(MachineAgentsReport.self, Self.antigravity)
        let agent = try #require(report.agents.first)
        #expect(agent.state == .needsSignIn)
        #expect(agent.keys.map(\.env) == ["GEMINI_API_KEY"])
        #expect(agent.keys.first?.alternative == true)
        #expect(agent.signIn.last?.kind == "terminal")
        #expect(agent.signIn.last?.id == "terminal-login")
        let hermes = try #require(try decode(MachineAgentsReport.self, Self.agents).agents.first)
        #expect(hermes.keys.allSatisfy { $0.alternative == nil })
        let named = BridgeModelName.split("antigravity-acp/gemini-4-neon", agentType: .claudeCode)
        #expect(named.providerID == "antigravity-acp")
        #expect(named.modelID == "gemini-4-neon")
    }

    @Test func schedulesDecodeAsTheBridgeWritesThem() throws {
        let decoded = try decode([MachineSchedule].self, Self.schedules)
        let schedule = try #require(decoded.first)
        #expect(schedule.rule == ScheduleRule(kind: .daily, hour: 7, minute: 30))
        #expect(schedule.thread == .continue)
        #expect(schedule.quiet)
        #expect(schedule.runs.map(\.outcome) == [.quiet, .caughtUp])
        #expect(schedule.runs.last?.settled == .answered)
        #expect(schedule.runs.last?.missed == 2)
        #expect(schedule.next == ISO8601DateFormatter().date(from: "2026-11-03T05:30:00Z"))
    }

    @Test func agentsDecodeAndAnUnknownStateIsAFailureNotAnError() throws {
        let report = try decode(MachineAgentsReport.self, Self.agents)
        #expect(report.agents.map(\.id) == ["hermes", "opencode", "future"])
        let hermes = try #require(report.agents.first)
        #expect(hermes.state == .ready)
        #expect(hermes.brain?.name == "llama-swap")
        #expect(hermes.models.map(\.name) == ["Flint", "Groot"])
        #expect(hermes.signIn.map(\.kind) == ["agent", "terminal"])
        #expect(report.agents[2].state == .failed)
        #expect(report.brains.first?.models.first?.name == "Flint")
    }

    @Test func aDraftEncodesTheRuleTheBridgeReads() throws {
        let draft = ScheduleDraft(
            text: "news", rule: ScheduleRule(kind: .weekly, hour: 9, minute: 0, weekday: 2),
            timeZone: "Europe/Helsinki", thread: .fresh, quiet: false)
        let json = try #require(
            try JSONSerialization.jsonObject(with: BridgeCoding.encoder.encode(draft)) as? [String: Any])
        let rule = try #require(json["rule"] as? [String: Any])
        #expect(rule["kind"] as? String == "weekly")
        #expect(rule["weekday"] as? Int == 2)
        #expect(json["thread"] as? String == "fresh")
    }

    @Test func anAgentConversationSplitsIntoItsAgentAndModel() {
        let named = BridgeModelName.split(
            "hermes/custom:nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf", agentType: .claudeCode)
        #expect(named.providerID == "hermes")
        #expect(named.modelID == "custom:nemotron-3.5-bolt-74b-a9b-24gb-abliterated-gguf")
        #expect(BridgeModelName.split("opus", agentType: .claudeCode).providerID == nil)
    }

    @Test func aDailyRuleAsksAtTheSameMomentTheMachineWould() throws {
        var helsinki = Calendar(identifier: .gregorian)
        helsinki.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        let rule = ScheduleRule(kind: .daily, hour: 7, minute: 30)
        let from = try #require(ISO8601DateFormatter().date(from: "2026-11-02T19:02:30Z"))
        #expect(rule.next(after: from, calendar: helsinki) == ISO8601DateFormatter().date(from: "2026-11-03T05:30:00Z"))
    }
}
