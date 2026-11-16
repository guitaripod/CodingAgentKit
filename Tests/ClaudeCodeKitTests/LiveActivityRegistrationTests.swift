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

    @Test("A card names its installation, and a device names how to start one")
    func deviceAndStarter() throws {
        let body = try Self.body(
            LiveActivityRegistration(
                token: "ab", environment: "production", startedAt: Date(timeIntervalSince1970: 0),
                title: "Fix it", deviceID: "D1"))
        #expect(body["deviceID"] as? String == "D1")
        let device = DevicePushRegistration(
            token: "t", environment: "production",
            liveActivity: LiveActivityStarter(
                token: "s", deviceID: "D1", profileID: "p", profileName: "studio", follows: true,
                cardLimit: 1, muted: ["x"]))
        let data = try BridgeCoding.encoder.encode(device)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let starter = try #require(object["liveActivity"] as? [String: Any])
        #expect(Set(starter.keys) == ["token", "deviceID", "profileID", "profileName", "follows", "cardLimit", "muted"])
        let plain = try BridgeCoding.encoder.encode(DevicePushRegistration(token: "t", environment: "production"))
        let plainObject = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(plainObject["liveActivity"] == nil)
    }
}
