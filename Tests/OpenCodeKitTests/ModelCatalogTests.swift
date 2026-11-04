import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

/// The model catalog is read once for many readers and held for a few minutes.
@Suite struct ModelCatalogTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func bump() { lock.withLock { value += 1 } }
    }

    @Test func readsTogetherShareOneRequestAndAFreshCopyIsReused() async throws {
        let catalog = OpenCodeV2ModelCatalog()
        let reads = Counter()
        let read: @Sendable () async throws -> [OC2Model] = {
            reads.bump()
            try await Task.sleep(for: .milliseconds(100))
            return []
        }
        async let first = catalog.models(read)
        async let second = catalog.models(read)
        _ = try await (first, second)
        _ = try await catalog.models(read)
        #expect(reads.count == 1)
    }

    @Test func aFailedReadIsNotHeld() async throws {
        let catalog = OpenCodeV2ModelCatalog()
        let reads = Counter()
        struct Down: Error {}
        _ = try? await catalog.models { reads.bump(); throw Down() }
        _ = try await catalog.models { reads.bump(); return [] }
        #expect(reads.count == 2)
    }
}
