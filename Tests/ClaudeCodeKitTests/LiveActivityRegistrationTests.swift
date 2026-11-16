import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite("A Live Activity's registration as claude-bridge reads it")
struct LiveActivityRegistrationTests {
    private static func body(_ registration: LiveActivityRegistration) throws -> [String: Any] {
        let data = try BridgeCoding.encoder.encode(registration)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("A card that should settle quietly sends the body every bridge has always read")
    func withoutEndAlert() throws {
        let body = try Self.body(
            LiveActivityRegistration(
                token: "ab", environment: "production", startedAt: Date(timeIntervalSince1970: 0),
                title: "Fix it"))
        #expect(Set(body.keys) == ["token", "environment", "startedAt", "title"])
    }

    @Test("A card that should open the island at its ending says how")
    func withEndAlert() throws {
        let body = try Self.body(
            LiveActivityRegistration(
                token: "ab", environment: "production", startedAt: Date(timeIntervalSince1970: 0),
                title: "Fix it", endAlert: "silent"))
        #expect(body["endAlert"] as? String == "silent")
        let decoded = try JSONDecoder().decode(
            LiveActivityRegistration.self,
            from: Data(#"{"token":"a","environment":"production","startedAt":0,"title":"t"}"#.utf8))
        #expect(decoded.endAlert == nil)
    }
}
