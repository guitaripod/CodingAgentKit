#if os(macOS)
import Foundation
import Testing

@testable import CodingAgentKitApple

@Suite("Private secrets file")
struct PrivateSecretsFileTests {
    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("secrets-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("com.codingagentkit.credentials.secrets.json")
    }

    @Test("A secret written is read back, and a removed one is gone")
    func roundTrip() throws {
        let file = PrivateSecretsFile(url: Self.scratch())
        #expect(try file.value(for: "arch") == nil)
        try file.setValue("hunter2", for: "arch")
        try file.setValue("tailscode", for: "omp")
        #expect(try file.value(for: "arch") == "hunter2")
        #expect(try file.value(for: "omp") == "tailscode")
        try file.removeValue(for: "arch")
        #expect(try file.value(for: "arch") == nil)
        #expect(try file.value(for: "omp") == "tailscode")
    }

    @Test("Only its user can open it, in a folder only its user can list")
    func permissions() throws {
        let url = Self.scratch()
        try PrivateSecretsFile(url: url).setValue("hunter2", for: "arch")
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let folder = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path)
        #expect((file[.posixPermissions] as? Int) == 0o600)
        #expect((folder[.posixPermissions] as? Int) == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == [url.lastPathComponent], "no staging file is left behind")
    }

    @Test("A file that cannot be read is an error, never an empty map a write would replace")
    func unreadableIsAnError() throws {
        let url = Self.scratch()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let file = PrivateSecretsFile(url: url)
        #expect(throws: (any Error).self) { try file.value(for: "arch") }
        #expect(throws: (any Error).self) { try file.setValue("x", for: "arch") }
        #expect(try Data(contentsOf: url) == Data("not json".utf8))
    }

    @Test("Each keychain service is a file of its own")
    func perService() {
        let credentials = PrivateSecretsFile(service: "com.codingagentkit.credentials")
        let other = PrivateSecretsFile(service: "com.codingagentkit/delegate")
        #expect(credentials.url != other.url)
        #expect(credentials.url.lastPathComponent == "com.codingagentkit.credentials.secrets.json")
        #expect(other.url.lastPathComponent == "com.codingagentkit_delegate.secrets.json")
        #expect(credentials.url.deletingLastPathComponent().lastPathComponent == "CodingAgentKit")
    }
}
#endif
