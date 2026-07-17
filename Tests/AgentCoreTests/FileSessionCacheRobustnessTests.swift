import Foundation
import Testing

@testable import AgentCore

@Suite struct FileSessionCacheRobustnessTests {
    /// A fresh, isolated cache directory that is removed when `body` returns.
    private func withTempDir(
        _ label: String, _ body: (URL) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cak-cache-robust-\(label)-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    @Test func fullFidelityRoundTripSurvivesColdStart() async throws {
        try await withTempDir("fidelity") { dir in
            let cache = try FileSessionCache(directory: dir)

            let session = AgentSession(
                id: "ses_full", agentType: .claudeCode, title: "Full",
                parentID: "ses_parent", directory: "/work/repo",
                createdAt: Date(timeIntervalSince1970: 100),
                updatedAt: Date(timeIntervalSince1970: 200),
                isActive: true, model: "claude-fable-5", reasoningEffort: "high")
            await cache.store([session], for: .claudeCode)

            let message = ChatMessage(
                id: "m1", role: .assistant, agentType: .claudeCode,
                parts: [
                    MessagePart(id: "p_text", kind: .text("hello")),
                    MessagePart(id: "p_reason", kind: .reasoning("thinking")),
                    MessagePart(
                        id: "p_tool",
                        kind: .tool(
                            ToolCall(
                                id: "t1", name: "bash", status: .completed,
                                input: .object(["cmd": .string("ls")]),
                                output: "done", title: "Run"))),
                    MessagePart(
                        id: "p_file",
                        kind: .file(FileReference(path: "/a.txt", mime: "text/plain"))),
                    MessagePart(id: "p_unknown", kind: .unknown(type: "widget")),
                ],
                createdAt: Date(timeIntervalSince1970: 100),
                completedAt: Date(timeIntervalSince1970: 150),
                isStreaming: false, error: "boom", costUSD: 0.5,
                providerID: "anthropic", modelID: "claude-fable-5", totalTokens: 1234)
            await cache.store([message], for: "ses_full")

            let reloaded = try FileSessionCache(directory: dir)
            #expect(await reloaded.sessions(for: .claudeCode) == [session])
            #expect(await reloaded.messages(for: "ses_full") == [message])
        }
    }

    @Test func distinctIdsThatSanitizeAlikeDoNotCrossContaminate() async throws {
        try await withTempDir("collision") { dir in
            let cache = try FileSessionCache(directory: dir)

            let cases: [(id: String, text: String)] = [
                ("a/b", "slashAB"),
                ("a.b", "dotAB"),
                ("a:b", "colonAB"),
                ("a b", "spaceAB"),
                ("a_b", "underscoreAB"),
            ]

            for (id, text) in cases {
                await cache.store(
                    [
                        ChatMessage(
                            id: "m", role: .assistant, agentType: .openCode,
                            parts: [MessagePart(id: "p", kind: .text(text))],
                            createdAt: Date(timeIntervalSince1970: 0))
                    ], for: id)
            }

            for (id, text) in cases {
                #expect(await cache.messages(for: id).first?.text == text)
            }

            let reloaded = try FileSessionCache(directory: dir)
            for (id, text) in cases {
                #expect(await reloaded.messages(for: id).first?.text == text)
            }
        }
    }

    @Test func pathTraversalIdIsNeutralizedAndStillRoundTrips() async throws {
        try await withTempDir("traversal") { dir in
            let cache = try FileSessionCache(directory: dir)
            let evilID = "../../../etc/passwd"

            await cache.store(
                [
                    ChatMessage(
                        id: "m", role: .user, agentType: .openCode,
                        parts: [MessagePart(id: "p", kind: .text("trapped"))],
                        createdAt: Date(timeIntervalSince1970: 0))
                ], for: evilID)

            #expect(await cache.messages(for: evilID).first?.text == "trapped")

            let parent = dir.deletingLastPathComponent()
            let leaked = parent.appendingPathComponent("etc/passwd.json")
            #expect(!FileManager.default.fileExists(atPath: leaked.path))
        }
    }

    @Test func corruptMessagesFileReadsEmptyWithoutCrashingOrCorruptingPeers() async throws {
        try await withTempDir("corrupt-msgs") { dir in
            let cache = try FileSessionCache(directory: dir)

            await cache.store(
                [
                    ChatMessage(
                        id: "m", role: .assistant, agentType: .openCode,
                        parts: [MessagePart(id: "p", kind: .text("healthy"))],
                        createdAt: Date(timeIntervalSince1970: 0))
                ], for: "healthySes")

            let garbage = dir.appendingPathComponent("messages-corruptSes.json")
            try Data("{ this is not <valid> json ]".utf8).write(to: garbage)

            #expect(await cache.messages(for: "corruptSes").isEmpty)
            #expect(await cache.messages(for: "healthySes").first?.text == "healthy")

            await cache.store(
                [
                    ChatMessage(
                        id: "m2", role: .assistant, agentType: .openCode,
                        parts: [MessagePart(id: "p2", kind: .text("recovered"))],
                        createdAt: Date(timeIntervalSince1970: 0))
                ], for: "corruptSes")
            #expect(await cache.messages(for: "corruptSes").first?.text == "recovered")
        }
    }

    @Test func corruptSessionsFileReadsEmptyWithoutAffectingOtherAgentType() async throws {
        try await withTempDir("corrupt-sess") { dir in
            let cache = try FileSessionCache(directory: dir)

            let good = AgentSession(
                id: "ses_cc", agentType: .claudeCode, title: "CC",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 1))
            await cache.store([good], for: .claudeCode)

            let garbage = dir.appendingPathComponent("sessions-openCode.json")
            try Data("not json at all".utf8).write(to: garbage)

            #expect(await cache.sessions(for: .openCode).isEmpty)
            #expect(await cache.sessions(for: .claudeCode) == [good])
        }
    }

    @Test func savedFileIs0600AndDirectoryIs0700() async throws {
        try await withTempDir("perms") { dir in
            let cache = try FileSessionCache(directory: dir)
            await cache.store(
                [
                    ChatMessage(
                        id: "m", role: .assistant, agentType: .openCode,
                        parts: [MessagePart(id: "p", kind: .text("secret"))],
                        createdAt: Date(timeIntervalSince1970: 0))
                ], for: "permSes")

            let fileAttrs = try FileManager.default.attributesOfItem(
                atPath: dir.appendingPathComponent("messages-permSes.json").path)
            let filePerms = try #require(
                (fileAttrs[.posixPermissions] as? NSNumber)?.intValue)
            #expect(filePerms & 0o777 == 0o600)

            let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
            let dirPerms = try #require(
                (dirAttrs[.posixPermissions] as? NSNumber)?.intValue)
            #expect(dirPerms & 0o777 == 0o700)
        }
    }
}
