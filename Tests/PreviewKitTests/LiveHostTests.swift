import AgentCore
import Foundation
import Testing

@testable import PreviewKit

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PREVIEWD_URL"] != nil))
struct LiveHostTests {
    private func client() throws -> PreviewClient {
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["PREVIEWD_URL"] ?? ""))
        let host = try #require(url.host)
        let config = try #require(PreviewClient.config(host: host, port: url.port ?? 4300, password: nil))
        return PreviewClient(config: config)
    }

    @Test func hostAnswersItsStatusAndChecklist() async throws {
        let client = try client()
        let status = try await client.status()
        #expect(status.proto == PreviewProto.current)
        #expect(status.streaming.maximumFramesPerSecond == 60)
        let checks = try await client.doctor()
        #expect(checks.contains { $0.id == "xcode" })
    }

    @Test func aLiveSessionStreamsDecodablePictures() async throws {
        let client = try client()
        let sessions = try await client.sessions()
        let live = try #require(sessions.first { $0.state == .live })
        var frames = 0
        var heartbeats = 0
        var hello = false
        var firstBytes: Data?
        let began = ContinuousClock.now
        for try await record in client.frames(of: live.id) {
            switch record {
            case .event: hello = true
            case .heartbeat: heartbeats += 1
            case .frame(_, let jpeg):
                frames += 1
                if firstBytes == nil { firstBytes = jpeg.prefix(3) }
            }
            if frames >= 1 && ContinuousClock.now - began > .seconds(7) { break }
        }
        #expect(hello)
        #expect(frames >= 1)
        #expect(firstBytes == Data([0xFF, 0xD8, 0xFF]))
        #expect(heartbeats >= 1)
        let latest = try await client.latestFrame(live.id)
        #expect(latest.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func eventsReplayTheSessionsHistory() async throws {
        let client = try client()
        let live = try #require(try await client.sessions().first { $0.state == .live })
        var kinds: [String] = []
        for try await event in client.events(of: live.id) {
            kinds.append(event.kind)
            if kinds.contains("build.done") { break }
        }
        #expect(kinds.contains("state"))
        #expect(kinds.contains("build.done"))
    }
}
