import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct OpenCodeCommandMappingTests {
    private func decode(_ json: String) throws -> [OCCommand] {
        try JSONDecoder().decode([OCCommand].self, from: Data(json.utf8))
    }

    /// Shapes taken from a live `GET /command` on opencode 1.18.
    @Test func realCatalogMapsToTheSharedCommandModel() throws {
        let commands = try decode(
            """
            [{"name":"init","description":"guided AGENTS.md setup","source":"command",
              "template":"...","hints":["$ARGUMENTS"]},
             {"name":"appstore-connect:asc-rejection-audit","description":"Catch rejections",
              "source":"mcp","template":"...","hints":["$1"]},
             {"name":"customize-opencode","description":"opencode config","source":"skill",
              "template":"...","hints":[]}]
            """)
        let mapped = commands.map { OpenCodeBackend.command(for: $0) }

        #expect(mapped[0].source == .custom)
        #expect(mapped[0].argumentHint == "<arguments>")
        #expect(mapped[0].takesArguments)
        #expect(mapped[1].source == .mcp)
        #expect(mapped[1].argumentHint == "<1>")
        #expect(mapped[1].invocation(arguments: "1.2.0")
            == "/appstore-connect:asc-rejection-audit 1.2.0")
        #expect(mapped[2].source == .skill)
        #expect(mapped[2].argumentHint == nil)
        #expect(!mapped[2].takesArguments)
    }
}
