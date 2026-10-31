import Foundation
import Testing

@testable import AgentCore

@Suite struct TranscriptWriteBudgetTests {
    @Test func aLightTranscriptIsNeverMadeToWait() {
        #expect(TranscriptWriteBudget.wait(sinceLastWrite: 0, lastBytes: 200_000) == 0)
        #expect(TranscriptWriteBudget.wait(sinceLastWrite: 0, lastBytes: 1_048_575) == 0)
    }

    @Test func aHeavyTranscriptAveragesNoMoreThanTheBudget() {
        let bytes = 44 * 1_048_576
        let quiet = TranscriptWriteBudget.quiet(after: bytes)
        #expect(Double(bytes) / quiet <= TranscriptWriteBudget.bytesPerSecond + 0.001)
        #expect(quiet > 20 * 60)
    }

    @Test func theWaitShrinksAsTheTimeSinceTheLastWritePasses() {
        let bytes = 8 * 1_048_576
        let quiet = TranscriptWriteBudget.quiet(after: bytes)
        #expect(TranscriptWriteBudget.wait(sinceLastWrite: 10, lastBytes: bytes) == quiet - 10)
        #expect(TranscriptWriteBudget.wait(sinceLastWrite: quiet + 1, lastBytes: bytes) == 0)
    }

    @Test func theCacheSaysWhatItLastWrote() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cak-cache-bytes")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir)
        #expect(await cache.lastStoredBytes(for: "s") == 0)
        let message = ChatMessage(
            id: "m", role: .assistant, agentType: .openCode,
            parts: [MessagePart(id: "p", kind: .text(String(repeating: "x", count: 5_000)))],
            createdAt: Date(timeIntervalSince1970: 0))
        await cache.store([message], for: "s")
        let bytes = await cache.lastStoredBytes(for: "s")
        let onDisk = try Data(contentsOf: dir.appendingPathComponent("messages-s.json"))
        #expect(bytes == onDisk.count)
        #expect(bytes > 5_000)
    }
}
