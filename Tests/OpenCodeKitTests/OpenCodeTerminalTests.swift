import AgentCore
import Foundation
import Testing

@testable import OpenCodeKit

@Suite struct ShellMarksTests {
    private func read(_ marks: inout ShellMarks, _ text: String) {
        marks.read(Data(text.utf8))
    }

    /// Bytes taken from a live opencode 2.0.32 pty running Arch's login bash, which prints
    /// systemd's context marks.
    @Test func systemdContextMarksGiveFolderAndProgram() {
        var marks = ShellMarks()
        read(
            &marks,
            "\u{1b}]3008;start=aa;type=shell;user=marcus;hostname=arch;cwd=/home/marcus\u{1b}\\\u{1b}]0;marcus@arch:~\u{07}\u{1b}[?2004h\u{1b}[32mmarcus@arch\u{1b}[0m:\u{1b}[34m~\u{1b}[0m$ "
        )
        #expect(marks.directory == "/home/marcus")
        #expect(marks.job == nil)
        read(&marks, "sudo vim notes.txt\r\n\u{1b}[?2004l\r\u{1b}]3008;start=bb;type=command;cwd=/home/marcus/Dev\u{1b}\\")
        #expect(marks.job == "vim")
        #expect(marks.directory == "/home/marcus/Dev")
        read(&marks, "\u{1b}[?1049h\u{1b}[?1049l")
        #expect(marks.job == "vim")
        read(&marks, "\u{1b}]3008;end=bb;exit=success\u{1b}\\\u{1b}]3008;start=aa;type=shell;cwd=/tmp/a\\x3bb\u{1b}\\")
        #expect(marks.job == nil)
        #expect(marks.directory == "/tmp/a;b")
    }

    @Test func finalTermMarksReadTheCommandAfterThePrompt() {
        var marks = ShellMarks()
        read(&marks, "\u{1b}]133;A\u{07}~/src > \u{1b}]133;B\u{07}")
        read(&marks, "FOO=1 cargo build --release\r\n\u{1b}]133;C\u{07}")
        #expect(marks.job == "cargo")
        read(&marks, "Compiling\r\n\u{1b}]133;D;0\u{07}\u{1b}]7;file://mac/Users/me/My%20Code\u{07}")
        #expect(marks.job == nil)
        #expect(marks.directory == "/Users/me/My Code")
    }

    @Test func unmarkedShellIsReadByTheAlternateScreen() {
        var marks = ShellMarks()
        read(&marks, "me@mac ~ % htop\r\n")
        #expect(marks.job == nil)
        read(&marks, "\u{1b}[?1049h\u{1b}[H")
        #expect(marks.job == "htop")
        read(&marks, "\u{1b}[?1049l")
        #expect(marks.job == nil)
    }

    @Test func marksCutAcrossPiecesAreStillRead() {
        var marks = ShellMarks()
        let whole = Array("\u{1b}]7;file://host/var/log\u{1b}\\".utf8)
        for byte in whole { marks.read(Data([byte])) }
        #expect(marks.directory == "/var/log")
    }
}

@Suite struct OpenCodeTerminalWireTests {
    @Test func utf16UnitsMatchJavaScriptLengths() {
        let text = "a é € 😀"
        #expect(UTF8Count.utf16Units(in: Data(text.utf8)) == text.utf16.count)
        let bytes = Data(text.utf8)
        let cut = bytes.count - 2
        let split = UTF8Count.utf16Units(in: bytes.prefix(cut)) + UTF8Count.utf16Units(in: bytes.suffix(from: cut))
        #expect(split == text.utf16.count)
    }

    @Test func inputHoldsBackACharacterCutInTwo() {
        let bytes = Data("ab€".utf8)
        #expect(UTF8Count.wholeCharacterPrefix(of: bytes) == bytes.count)
        #expect(UTF8Count.wholeCharacterPrefix(of: bytes.prefix(3)) == 2)
        #expect(UTF8Count.wholeCharacterPrefix(of: bytes.prefix(4)) == 2)
        #expect(UTF8Count.wholeCharacterPrefix(of: Data("ab".utf8)) == 2)
    }

    @Test func metaFrameIsReadAndOutputIsNot() {
        #expect(OpenCodeV2TerminalReader.metaCursor(Data([0]) + Data(#"{"cursor":262}"#.utf8)) == 262)
        #expect(OpenCodeV2TerminalReader.metaCursor(Data("{\"cursor\":1}".utf8)) == nil)
        #expect(OpenCodeV2TerminalReader.metaCursor(Data([0, 0x41])) == nil)
    }

    @Test func deskTravelsInTheTitle() {
        let title = OpenCodeV2TerminalHub.title(desk: "arch (Linux)")
        #expect(OpenCodeV2TerminalHub.desk(fromTitle: title) == "arch (Linux)")
        #expect(OpenCodeV2TerminalHub.desk(fromTitle: "Terminal 1a2b") == nil)
    }
}

/// Against a real opencode 2 server: `OPENCODE_LIVE_URL=http://127.0.0.1:4096`
/// `OPENCODE_LIVE_PASSWORD=…`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENCODE_LIVE_URL"] != nil), .serialized)
struct OpenCodeTerminalLiveTests {
    private var backend: OpenCodeBackend {
        let environment = ProcessInfo.processInfo.environment
        let url = URL(string: environment["OPENCODE_LIVE_URL"] ?? "")!
        let credentials = environment["OPENCODE_LIVE_PASSWORD"].map { BasicCredentials(password: $0) }
        return OpenCodeBackend(config: ServerConfig(baseURL: url, credentials: credentials))
    }

    private func collect(
        _ link: TerminalLink, until done: @escaping @Sendable (String) -> Bool, within seconds: Double = 10
    ) async -> String {
        let box = TextBox()
        let reader = Task {
            for await event in link.events {
                if case .output(let bytes) = event { box.append(String(decoding: bytes, as: UTF8.self)) }
                if case .state(let info) = event { box.note(info) }
                if done(box.text) { return }
            }
        }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done(box.text) { try? await Task.sleep(for: .milliseconds(50)) }
        reader.cancel()
        return box.text
    }

    @Test func shellOpensTypesResumesAndCloses() async throws {
        let backend = self.backend
        _ = try await backend.health()
        #expect(backend.capabilities.supportsTerminals)
        let desk = "kit-live-\(UUID().uuidString.prefix(6))"
        let opened = try await backend.openTerminal(
            TerminalOpenRequest(directory: "/tmp", desk: desk, cols: 100, rows: 30))
        #expect(opened.isRunning)
        #expect(opened.desk == desk)
        #expect(opened.cols == 100)
        let listed = try await backend.terminals()
        #expect(listed.contains { $0.id == opened.id && $0.desk == desk })

        let link = TerminalLink(backend: backend, id: opened.id)
        await link.start()
        await link.send(Data("echo kit-€-$((6*7))\r".utf8))
        let first = await collect(link, until: { $0.contains("kit-€-42") })
        #expect(first.contains("kit-€-42"))
        let position = try #require(await link.position)
        await link.detach()

        let again = TerminalLink(backend: backend, id: opened.id, from: position)
        await again.start()
        await again.send(Data("echo second-$((2+3))\r".utf8))
        let second = await collect(again, until: { $0.contains("second-5") })
        #expect(second.contains("second-5"))
        #expect(!second.contains("kit-€-42\r\n"))

        try await backend.resizeTerminal(opened.id, cols: 120, rows: 40)
        let resized = try #require(try await backend.terminal(opened.id))
        #expect(resized.cols == 120)
        #expect(resized.directory == "/tmp")

        await again.close()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await backend.terminal(opened.id) == nil)
    }

    @Test func endedShellSaysSo() async throws {
        let backend = self.backend
        let opened = try await backend.openTerminal(TerminalOpenRequest(desk: "kit-live-exit", cols: 80, rows: 24))
        let link = TerminalLink(backend: backend, id: opened.id)
        await link.start()
        await link.send(Data("exit 3\r".utf8))
        let ended = EndBox()
        let reader = Task {
            for await event in link.events {
                if case .ended(let code) = event { ended.set(code) }
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !ended.done { try? await Task.sleep(for: .milliseconds(50)) }
        reader.cancel()
        #expect(ended.done)
        #expect(ended.code == 3)
        try? await backend.closeTerminal(opened.id)
    }
}

private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    private var infos: [TerminalInfo] = []

    func append(_ text: String) { lock.withLock { value += text } }
    func note(_ info: TerminalInfo) { lock.withLock { infos.append(info) } }
    var text: String { lock.withLock { value } }
}

private final class EndBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int??

    func set(_ code: Int?) { lock.withLock { value = .some(code) } }
    var done: Bool { lock.withLock { value != nil } }
    var code: Int? { lock.withLock { value ?? nil } }
}
