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

    @Test func historyDiffReplayAndVariantsAnswerOnALiveSession() async throws {
        let client = try client()
        let live = try #require(try await client.sessions().first { $0.state == .live })
        let shots = try await client.history(live.id)
        #expect(!shots.isEmpty)
        let picture = try await client.historyPicture(live.id, try #require(shots.first).id)
        #expect(picture.prefix(2) == Data([0xFF, 0xD8]))
        let report = try await client.diff(live.id, a: try #require(shots.first).id, b: nil)
        #expect(report.width > 0)
        let replay = try await client.replay(live.id, seconds: 5)
        for record in replay {
            if case .frame(_, let jpeg) = record { #expect(jpeg.prefix(2) == Data([0xFF, 0xD8])) }
        }
        let job = try await client.startVariants(
            live.id, VariantsRequest(variants: [VariantSpec(label: "Dark", appearance: "dark")], settle: 0.5))
        var status = try await client.variantJob(job)
        for _ in 0..<40 where status.state == .running {
            try await Task.sleep(for: .milliseconds(500))
            status = try await client.variantJob(job)
        }
        #expect(status.state == .done)
        let variant = try await client.variantPicture(job, 0)
        #expect(variant.prefix(2) == Data([0xFF, 0xD8]))
    }
}
