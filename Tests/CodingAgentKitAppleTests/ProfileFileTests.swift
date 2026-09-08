import AgentCore
import Foundation
import Testing

@testable import CodingAgentKitApple

@Suite("Stored profiles")
struct ProfileFileTests {
    private static func json(_ entries: [String]) -> Data {
        Data("[\(entries.joined(separator: ","))]".utf8)
    }

    private static let claude = """
        {"id":"a","name":"arch","backend":"claudeCode","baseURL":"http://arch:4098","username":"claude"}
        """
    private static let opencode = """
        {"id":"b","name":"macbook","backend":"openCode","baseURL":"http://mac:4096","username":"opencode"}
        """
    private static let future = """
        {"id":"c","name":"arch","backend":"somethingLater","baseURL":"http://arch:4100","username":"x"}
        """

    @Test("A backend this build has no case for costs only itself, never the whole list")
    func unknownBackendKeepsTheRest() throws {
        let file = try ProfileFile.read(Self.json([Self.claude, Self.opencode, Self.future]))
        #expect(file.known.map(\.id) == ["a", "b"])
        #expect(file.unreadable.count == 1)
    }

    @Test("A profile this build cannot read survives a save of the ones it can")
    func unknownBackendSurvivesAWrite() throws {
        var file = try ProfileFile.read(Self.json([Self.claude, Self.future]))
        file.replace(
            ConnectionProfile(
                id: "a", name: "arch renamed", backend: .claudeCode,
                baseURL: URL(string: "http://arch:4098")!, username: "claude"))
        let rewritten = try ProfileFile.read(try file.encoded())
        #expect(rewritten.known.map(\.name) == ["arch renamed"])
        #expect(rewritten.unreadable.count == 1)
        let carried = try JSONSerialization.jsonObject(with: rewritten.unreadable[0])
        #expect((carried as? [String: Any])?["backend"] as? String == "somethingLater")
    }

    @Test("Deleting a profile leaves the unreadable one where it was")
    func deleteKeepsTheUnknown() throws {
        var file = try ProfileFile.read(Self.json([Self.claude, Self.future]))
        file.remove(id: "a")
        let rewritten = try ProfileFile.read(try file.encoded())
        #expect(rewritten.known.isEmpty)
        #expect(rewritten.unreadable.count == 1)
    }

    @Test("Bytes that are not a list of profiles still throw, so a save cannot rebuild from nothing")
    func malformedStillThrows() {
        #expect(throws: (any Error).self) { try ProfileFile.read(Data("{\"not\":\"a list\"}".utf8)) }
        #expect(throws: (any Error).self) { try ProfileFile.read(Data("nonsense".utf8)) }
    }

    @Test("An empty file is an empty list rather than a failure")
    func emptyReadsEmpty() throws {
        #expect(try ProfileFile.read(Data()) == ProfileFile())
        #expect(try ProfileFile.read(Data("[]".utf8)).known.isEmpty)
    }
}
