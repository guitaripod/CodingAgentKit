import AgentCore
import Foundation
import Testing

@testable import DelegateKit

/// Runs only against a real daemon: `DELEGATE_LIVE_HOST=127.0.0.1 DELEGATE_LIVE_PASSWORD=… swift test --filter DelegateLiveTests`.
@Suite struct DelegateLiveTests {
    private static var client: DelegateClient? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["DELEGATE_LIVE_HOST"], let password = env["DELEGATE_LIVE_PASSWORD"],
            let config = DelegateClient.config(host: host, password: password)
        else { return nil }
        return DelegateClient(config: config)
    }

    @Test func theDaemonAnswersAndListsItsTiers() async throws {
        guard let client = Self.client else { return }
        let health = try await client.health()
        #expect(health.ok)
        let capabilities = try await client.capabilities()
        #expect(capabilities.api == 1)
        let tiers = try await client.tiers()
        #expect(tiers.map(\.tier) == capabilities.tiers)
        _ = try await client.stats()
        _ = try await client.runs(limit: 5)
    }

    @Test func aRunStreamsFromStartToFinish() async throws {
        guard let client = Self.client, let repo = ProcessInfo.processInfo.environment["DELEGATE_LIVE_REPO"] else { return }
        let packet = DelegatePacket.draft(taskClass: "docs", goal: "Create KIT.md containing exactly the word kit on one line.", repo: repo)
        var packetWithScope = packet
        packetWithScope.paths = ["KIT.md"]
        let runID = try await client.start(packet: packetWithScope, overrides: DelegateOverrides(tier: "t1", ceiling: "t1"))
        var kinds: [String] = []
        var finished: DelegateRunStatus?
        for try await envelope in client.events(runID: runID) {
            switch envelope.event {
            case .runStarted: kinds.append("run_started")
            case .runFinished(let status, _, _, _, _):
                kinds.append("run_finished")
                finished = status
            default: break
            }
        }
        #expect(kinds.first == "run_started")
        #expect(kinds.last == "run_finished")
        #expect(finished == .passed)
        let detail = try await client.run(id: runID)
        #expect(detail.run.status == .passed)
        #expect(!detail.attempts.isEmpty)
    }
}
