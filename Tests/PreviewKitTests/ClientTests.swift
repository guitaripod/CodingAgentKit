import AgentCore
import Foundation
import Testing

@testable import PreviewKit

@Suite struct ClientTests {
    @Test func configUsesTheHostsOwnPort() throws {
        let config = try #require(PreviewClient.config(host: "macbook", password: "secret"))
        #expect(config.baseURL.absoluteString == "http://macbook:4300")
        #expect(config.credentials?.username == "preview")
    }

    @Test func sessionRequestEncodesWhatTheHostReads() throws {
        let request = SessionRequest(
            project: ProjectRef(path: "/Users/anna/PhotoNotes"), deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            launchArguments: ["--screen", "notes"])
        let json = try #require(
            JSONSerialization.jsonObject(with: PreviewJSON.encoder.encode(request)) as? [String: Any])
        #expect(json["deviceType"] as? String == "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro")
        #expect(json["watch"] as? Bool == true)
        #expect((json["project"] as? [String: Any])?["path"] as? String == "/Users/anna/PhotoNotes")
    }

    @Test func hostSessionJSONDecodes() throws {
        let json = """
            {"id":"o9v59k","state":"live","device":{"udid":"24D9","name":"pv-o9v59k","deviceType":"t","runtime":"r"},
             "app":{"name":"PhotoNotes","bundleID":"dev.guitaripod.photonotes"},
             "project":{"path":"/Users/marcus/pvtest/PhotoNotes"},
             "lastBuild":{"ok":true,"path":"rebuilt","trigger":"edit","seconds":1.8,"finishedAt":"2026-10-14T21:40:12Z","issues":[]},
             "frame":{"width":604,"height":1312},"startedAt":"2026-10-14T21:39:40Z","restarts":0}
            """
        let info = try PreviewJSON.decoder.decode(SessionInfo.self, from: Data(json.utf8))
        #expect(info.state == .live)
        #expect(info.lastBuild?.path == .rebuilt)
        #expect(info.frame == FrameInfo(width: 604, height: 1312))
    }
}
