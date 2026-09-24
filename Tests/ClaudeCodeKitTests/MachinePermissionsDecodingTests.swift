import AgentCore
import Foundation
import Testing

@testable import ClaudeCodeKit

@Suite struct MachinePermissionsDecodingTests {
    private func decode(_ json: String) throws -> MachinePermissions {
        try BridgeCoding.decoder.decode(MachinePermissions.self, from: Data(json.utf8))
    }

    /// The answer a Mac bridge gives before anybody has switched on Full Disk Access.
    @Test func aMacWithoutFullDiskAccessIsIncomplete() throws {
        let permissions = try decode(
            #"""
            {"platform":"macos","host":"macbook","executable":"/Users/m/claude-bridge",
             "grants":[{"id":"fullDiskAccess","state":"missing"}],
             "requestedAt":"2026-09-24T09:30:00Z"}
            """#)

        #expect(permissions.platform == .macOS)
        #expect(permissions.host == "macbook")
        #expect(permissions.missing.map(\.kind) == [.fullDiskAccess])
        #expect(!permissions.isComplete)
        #expect(permissions.requestedAt != nil)
    }

    /// A newer bridge may name grants and states this build cannot explain; they are left out
    /// rather than failing the answer, so an old client never loses the grants it does know.
    @Test func grantsThisBuildCannotExplainAreLeftOut() throws {
        let permissions = try decode(
            #"""
            {"platform":"macos","grants":[
              {"id":"fullDiskAccess","state":"granted"},
              {"id":"automation","state":"missing"},
              {"id":"fullDiskAccess","state":"pending"}]}
            """#)

        #expect(permissions.known.count == 1)
        #expect(permissions.isComplete)
    }

    /// A Linux machine has nothing to grant and says so with an empty list.
    @Test func linuxHasNothingToGrant() throws {
        let permissions = try decode(#"{"platform":"linux","grants":[]}"#)

        #expect(permissions.platform == .linux)
        #expect(permissions.known.isEmpty)
        #expect(permissions.isComplete)
    }
}
