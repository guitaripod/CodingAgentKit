import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

/// Every conversation on one opencode 2 server shares one event connection.
@Suite struct EventHubTests {
    final class Dialer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuations: [OpenCodeV2EventHub.Stream.Continuation] = []
        private(set) var terminated = 0

        var dials: Int { lock.withLock { continuations.count } }

        func open() -> OpenCodeV2EventHub.Stream {
            let (stream, continuation) = OpenCodeV2EventHub.Stream.makeStream()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.terminated += 1 }
            }
            lock.withLock { continuations.append(continuation) }
            return stream
        }

        func send(_ json: String) {
            lock.withLock { continuations.last }?.yield(SSEvent(id: nil, type: nil, data: json))
        }

        func hangUp() { lock.withLock { continuations.last }?.finish() }
    }

    private static let connected = #"{"type":"server.connected","data":{}}"#
    private static let delta = #"{"type":"session.text.delta","data":{"sessionID":"s1","delta":"hi"}}"#

    private func next(_ iterator: inout OpenCodeV2EventHub.Stream.AsyncIterator) async throws -> String? {
        try await iterator.next()?.data
    }

    @Test func subscribersShareOneConnection() async throws {
        let dialer = Dialer()
        let hub = OpenCodeV2EventHub(open: { dialer.open() })
        var first = await hub.subscribe().makeAsyncIterator()
        var second = await hub.subscribe().makeAsyncIterator()
        #expect(dialer.dials == 1)

        dialer.send(Self.delta)
        #expect(try await next(&first) == Self.delta)
        #expect(try await next(&second) == Self.delta)
    }

    @Test func aLateSubscriberIsHandedTheConnectedFrameItMissed() async throws {
        let dialer = Dialer()
        let hub = OpenCodeV2EventHub(open: { dialer.open() })
        var first = await hub.subscribe().makeAsyncIterator()
        dialer.send(Self.connected)
        #expect(try await next(&first) == Self.connected)

        var late = await hub.subscribe().makeAsyncIterator()
        #expect(try await next(&late) == Self.connected)
        #expect(dialer.dials == 1)
    }

    @Test func anEndedConnectionEndsEverySubscriberAndTheNextOneDialsAgain() async throws {
        let dialer = Dialer()
        let hub = OpenCodeV2EventHub(open: { dialer.open() })
        var first = await hub.subscribe().makeAsyncIterator()
        var second = await hub.subscribe().makeAsyncIterator()
        dialer.hangUp()
        #expect(try await next(&first) == nil)
        #expect(try await next(&second) == nil)
        #expect(await hub.subscriberCount == 0)

        _ = await hub.subscribe()
        #expect(dialer.dials == 2)
    }

    @Test func theLastSubscriberLeavingHangsUp() async throws {
        let dialer = Dialer()
        let hub = OpenCodeV2EventHub(open: { dialer.open() })
        let watcher = Task {
            for try await _ in await hub.subscribe() {}
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(dialer.dials == 1)
        watcher.cancel()
        for _ in 0..<100 where dialer.terminated == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dialer.terminated == 1)
        #expect(await hub.subscriberCount == 0)
    }
}
