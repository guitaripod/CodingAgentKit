import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

private actor Counter {
    var count = 0
    func bump() -> Int {
        count += 1
        return count
    }
}

private func unreachable() -> ServerConfig {
    ServerConfig(baseURL: URL(string: "http://127.0.0.1:1")!, credentials: nil)
}

@Suite struct OpenCodeNegotiationTests {
    @Test func aGenerationIsAskedOnceAndSharedByConcurrentCallers() async throws {
        let asked = Counter()
        let negotiation = OpenCodeNegotiation {
            _ = await asked.bump()
            try await Task.sleep(for: .milliseconds(20))
            return OpenCodeV2Backend(config: unreachable())
        }
        async let first = negotiation.generation()
        async let second = negotiation.generation()
        _ = try await (first, second)
        _ = try await negotiation.generation()
        #expect(await asked.count == 1)
        #expect(negotiation.capabilities?.supportsRenaming == true)
    }

    @Test func aFailedAskIsNotRemembered() async {
        let asked = Counter()
        let negotiation = OpenCodeNegotiation {
            let n = await asked.bump()
            if n == 1 { throw AgentError.connection("refused") }
            return OpenCodeV1Backend(config: unreachable())
        }
        await #expect(throws: AgentError.self) { try await negotiation.generation() }
        #expect(negotiation.capabilities == nil)
        _ = try? await negotiation.generation()
        #expect(await asked.count == 2)
        #expect(negotiation.capabilities?.supportsRenaming == false)
    }

    @Test func aRefreshAsksAgainEvenWhenAnAnswerIsHeld() async throws {
        let asked = Counter()
        let negotiation = OpenCodeNegotiation {
            _ = await asked.bump()
            return OpenCodeV2Backend(config: unreachable())
        }
        _ = try await negotiation.generation()
        _ = try await negotiation.refresh()
        #expect(await asked.count == 2)
    }

    @Test func theFacadeReportsTheFloorUntilTheServerHasAnswered() {
        let backend = OpenCodeBackend { OpenCodeV2Backend(config: unreachable()) }
        #expect(backend.capabilities == OpenCodeV1Backend.baseline)
        #expect(backend.agentType == .openCode)
    }
}
