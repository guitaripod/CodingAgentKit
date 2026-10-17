import Foundation
import Testing

@testable import AgentCore

@Suite struct FileSessionCachePruningTests {
    private static let day: TimeInterval = 86_400

    private static func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "cak-prune-\(UUID().uuidString)")
    }

    private static func write(
        _ name: String, bytes: Int, age: TimeInterval, in directory: URL, now: Date
    ) throws {
        let url = directory.appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private static func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    private static func message(_ text: String) -> [ChatMessage] {
        [
            ChatMessage(
                id: "m", role: .assistant, agentType: .claudeCode,
                parts: [MessagePart(id: "p", kind: .text(text))],
                createdAt: Date(timeIntervalSince1970: 0))
        ]
    }

    @Test func removesTranscriptsUntouchedForLongerThanTheAge() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir, pruning: nil)
        let now = Date()
        try Self.write("messages-old.json", bytes: 10, age: 61 * Self.day, in: dir, now: now)
        try Self.write("messages-recent.json", bytes: 10, age: 59 * Self.day, in: dir, now: now)

        let removed = await cache.prune(.init(maxAge: 60 * Self.day, maxBytes: 1_000), now: now)

        #expect(removed == ["messages-old.json"])
        #expect(Self.names(in: dir) == ["messages-recent.json"])
    }

    @Test func removesLeastRecentlyUsedFirstUntilUnderTheByteCap() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir, pruning: nil)
        let now = Date()
        try Self.write("messages-a.json", bytes: 100, age: 4 * Self.day, in: dir, now: now)
        try Self.write("messages-b.json", bytes: 100, age: 3 * Self.day, in: dir, now: now)
        try Self.write("messages-c.json", bytes: 100, age: 2 * Self.day, in: dir, now: now)
        try Self.write("messages-d.json", bytes: 100, age: 1 * Self.day, in: dir, now: now)

        let removed = await cache.prune(.init(maxAge: 60 * Self.day, maxBytes: 250), now: now)

        #expect(removed == ["messages-a.json", "messages-b.json"])
        #expect(Self.names(in: dir) == ["messages-c.json", "messages-d.json"])
    }

    @Test func leavesSessionListsAndUnrelatedFilesAlone() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir, pruning: nil)
        let now = Date()
        try Self.write("sessions-claudeCode.json", bytes: 500, age: 400 * Self.day, in: dir, now: now)
        try Self.write("notes.txt", bytes: 500, age: 400 * Self.day, in: dir, now: now)

        let removed = await cache.prune(.init(maxAge: Self.day, maxBytes: 1), now: now)

        #expect(removed.isEmpty)
        #expect(Self.names(in: dir) == ["sessions-claudeCode.json", "notes.txt"])
    }

    @Test func neverRemovesATranscriptThisProcessHasReadOrWritten() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir, pruning: nil)
        let now = Date()
        await cache.store(Self.message("written"), for: "held-write")
        try Self.write("messages-held-read.json", bytes: 10, age: 90 * Self.day, in: dir, now: now)
        _ = await cache.messages(for: "held-read")
        try Self.write("messages-cold.json", bytes: 10, age: 90 * Self.day, in: dir, now: now)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-90 * Self.day)],
            ofItemAtPath: dir.appendingPathComponent("messages-held-write.json").path)

        let removed = await cache.prune(.init(maxAge: 60 * Self.day, maxBytes: 1), now: now)

        #expect(removed == ["messages-cold.json"])
        #expect(Self.names(in: dir).contains("messages-held-write.json"))
        #expect(Self.names(in: dir).contains("messages-held-read.json"))
    }

    @Test func readingATranscriptCountsAsUsingIt() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let writer = try FileSessionCache(directory: dir, pruning: nil)
        await writer.store(Self.message("kept"), for: "s")
        let url = dir.appendingPathComponent("messages-s.json")
        let longAgo = Date().addingTimeInterval(-90 * Self.day)
        try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)

        let reader = try FileSessionCache(directory: dir, pruning: nil)
        #expect(await reader.messages(for: "s").first?.text == "kept")

        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]
        #expect((modified as? Date ?? longAgo) > longAgo.addingTimeInterval(Self.day))
    }

    @Test func aMissingDirectoryEntryDoesNotStopThePass() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = try FileSessionCache(directory: dir, pruning: nil)
        try FileManager.default.removeItem(at: dir)

        #expect(await cache.prune(.standard).isEmpty)
    }

    @Test func openingACacheStartsOnePruneInTheBackground() async throws {
        let dir = Self.directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        try Self.write("messages-ancient.json", bytes: 10, age: 90 * Self.day, in: dir, now: now)
        try Self.write("messages-fresh.json", bytes: 10, age: Self.day, in: dir, now: now)

        let cache = try FileSessionCache(directory: dir)
        for _ in 0..<100 where Self.names(in: dir).contains("messages-ancient.json") {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(Self.names(in: dir) == ["messages-fresh.json"])
        _ = cache
    }
}
