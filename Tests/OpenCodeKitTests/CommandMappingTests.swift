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

    /// `GET /command` answers with prompt templates only — its schema requires a `template` — so
    /// the words opencode's own client offers for its built-in actions are structurally absent.
    /// A command nobody can see is a command nobody has.
    @Test func builtinsAreOfferedBesideTheServersOwnCatalog() throws {
        let published = try decode(
            """
            [{"name":"init","description":"guided setup","source":"command",
              "template":"...","hints":[]}]
            """
        ).map { OpenCodeBackend.command(for: $0) }
        let claimed = Set(published.map(\.name))
        let offered = published + OpenCodeBackend.builtins.filter { !claimed.contains($0.name) }

        #expect(offered.map(\.name) == ["init", "compact"])
        #expect(offered[1].source == .builtin)
        #expect(!offered[1].takesArguments)
    }

    /// A machine that wrote its own `compact.md` has answered what the word means there, and the
    /// Kit does not argue with it.
    @Test func theServerWinsWhenItClaimsABuiltinsName() throws {
        let published = try decode(
            """
            [{"name":"compact","description":"mine","source":"command",
              "template":"...","hints":[]}]
            """
        ).map { OpenCodeBackend.command(for: $0) }
        let claimed = Set(published.map(\.name))
        let offered = published + OpenCodeBackend.builtins.filter { !claimed.contains($0.name) }

        #expect(offered.count == 1)
        #expect(offered[0].details == "mine")
    }

    @Test func opencodesOwnAliasReachesTheSameRoute() {
        #expect(OpenCodeBackend.isCompaction("compact"))
        #expect(OpenCodeBackend.isCompaction("summarize"))
        #expect(!OpenCodeBackend.isCompaction("context"))
    }
}

/// The command route is not the prompt route, and the differences are the kind a compiler cannot
/// catch: opencode requires `arguments` and takes the model as one `providerID/modelID` string,
/// where the prompt route takes an object. Both were got wrong here — the model was hardcoded nil
/// and could not have been sent as an object anyway — so the shape is asserted rather than assumed.
@Suite struct OpenCodeCommandRequestTests {
    /// Read back as the server reads it — a substring assertion would be checking Foundation's
    /// slash escaping rather than the shape opencode validates.
    private func body(_ run: CommandRun) throws -> [String: String] {
        let data = try JSONEncoder().encode(OpenCodeBackend.commandRequest(for: run))
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private let command = AgentCommand(name: "hinta-best", details: "", source: .custom)

    @Test func theModelIsOneSlashSeparatedString() throws {
        let sent = try body(
            CommandRun(
                command: command, arguments: "rtx 6000",
                model: ModelSelection(
                    providerID: "ollama", modelID: "nemotron-3.5-lightning:30b-mlx"),
                reasoningEffort: "high", agent: "build"))

        #expect(sent["command"] == "hinta-best")
        #expect(sent["model"] == "ollama/nemotron-3.5-lightning:30b-mlx")
        #expect(sent["variant"] == "high")
        #expect(sent["agent"] == "build")
        #expect(sent["arguments"] == "rtx 6000")
    }

    /// `arguments` is a required key: a command with nothing after it is an empty argument, not an
    /// absent one, and omitting it is a 400 that only ever reached a log line. Everything else is
    /// omitted rather than sent null, so the server's own defaults still decide.
    @Test func argumentsAreAlwaysWrittenAndNothingElseIsInvented() throws {
        let sent = try body(CommandRun(command: command))

        #expect(sent["arguments"] == "")
        #expect(sent.keys.sorted() == ["arguments", "command"])
    }
}
