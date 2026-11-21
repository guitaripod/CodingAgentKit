import AgentCore
import AgentTestSupport
import Foundation
import Testing

@Suite struct TerminalLinkTests {
    private func text(_ events: [TerminalLink.Event]) -> String {
        events.reduce(into: "") { text, event in
            if case .output(let bytes) = event { text += String(decoding: bytes, as: UTF8.self) }
        }
    }

    private func gather(
        _ link: TerminalLink, until done: @escaping @Sendable ([TerminalLink.Event]) -> Bool
    ) async -> [TerminalLink.Event] {
        let task = Task { () -> [TerminalLink.Event] in
            var seen: [TerminalLink.Event] = []
            for await event in link.events {
                seen.append(event)
                if done(seen) { break }
            }
            return seen
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            task.cancel()
        }
        let seen = await task.value
        timeout.cancel()
        return seen
    }

    @Test func whatIsTypedComesBackInOrder() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let info = try await backend.openTerminal(TerminalOpenRequest(directory: "/srv/app", cols: 90, rows: 30))
        let link = TerminalLink(backend: backend, id: info.id)
        await link.start()
        for word in ["echo ", "one ", "two ", "three\r"] { await link.send(Data(word.utf8)) }
        let seen = await gather(link) { self.text($0).contains("\r\none two three\r\n") }
        #expect(seen.contains(.reset(cols: 90, rows: 30)))
        #expect(seen.contains(.connection(.live)))
        #expect(text(seen).contains("echo one two three\r\none two three\r\n"))
    }

    @Test func aLinkThatComesBackWithItsPositionIsNotResent() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let info = try await backend.openTerminal(TerminalOpenRequest())
        let first = TerminalLink(backend: backend, id: info.id)
        await first.start()
        await first.send(Data("pwd\r".utf8))
        _ = await gather(first) { self.text($0).contains("/home/demo/project\r\n") }
        let position = await first.position
        await first.detach()
        let second = TerminalLink(backend: backend, id: info.id, from: position)
        await second.start()
        await second.send(Data("whoami\r".utf8))
        let seen = await gather(second) { self.text($0).contains("demo\r\n") }
        #expect(!seen.contains { if case .reset = $0 { true } else { false } })
        #expect(!text(seen).contains("/home/demo/project\r\n"))
    }

    @Test func aShellThatEndsAndAServerThatForgotAreToldApart() async throws {
        let backend = MockBackend(terminals: MockTerminalWorld())
        let ending = try await backend.openTerminal(TerminalOpenRequest())
        let link = TerminalLink(backend: backend, id: ending.id)
        await link.start()
        await link.send(Data("exit 3\r".utf8))
        let seen = await gather(link) { _ in false }
        #expect(seen.last == .ended(code: 3))

        let missing = TerminalLink(backend: backend, id: "no-such-terminal")
        await missing.start()
        let lost = await gather(missing) { _ in false }
        #expect(lost.last == .gone)
    }
}
