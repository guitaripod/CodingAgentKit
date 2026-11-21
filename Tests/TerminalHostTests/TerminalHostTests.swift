import Foundation
import Testing

@testable import TerminalHost
@testable import TerminalWire

@Suite struct TerminalFrameTests {
    @Test func framesSurviveAnyGrouping() throws {
        let info = TerminalInfo(
            id: "a", shell: "zsh", directory: "/tmp", job: "vim", cols: 120, rows: 40,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), session: "s", attached: 1, offset: 9)
        let frames: [TerminalFrame] = [
            .start(TerminalStart(offset: 42, reset: true, cols: 120, rows: 40)),
            .output(Data("hello \u{1b}[31mred\u{1b}[0m\r\n".utf8)),
            .state(info),
            .ping,
            .output(Data(repeating: 0x41, count: 70_000)),
            .exit(TerminalExit(code: 130)),
        ]
        let wire = frames.reduce(Data()) { $0 + $1.encoded() }
        for size in [1, 2, 5, 7, 4096, 16_384, wire.count] {
            var reader = TerminalFrameReader()
            var read: [TerminalFrame] = []
            var index = 0
            while index < wire.count {
                let end = min(index + size, wire.count)
                read += try reader.read(wire.subdata(in: index..<end))
                index = end
            }
            #expect(Self.joined(read) == Self.joined(frames), "piece size \(size)")
        }
    }

    @Test func aLengthNoFrameHasIsRefused() {
        var reader = TerminalFrameReader()
        #expect(throws: TerminalFrameReader.Failure.malformed) {
            _ = try reader.read(Data([3, 0xff, 0xff, 0xff, 0xff, 0]))
        }
    }

    @Test func anUnknownKindIsSkipped() throws {
        var reader = TerminalFrameReader()
        let unknown = Data([99, 0, 0, 0, 2, 1, 2])
        let frames = try reader.read(unknown + TerminalFrame.ping.encoded())
        #expect(frames == [.ping])
    }

    private static func joined(_ frames: [TerminalFrame]) -> [TerminalFrame] {
        var result: [TerminalFrame] = []
        for frame in frames {
            if case .output(let more) = frame, case .output(let held)? = result.last {
                result[result.count - 1] = .output(held + more)
            } else {
                result.append(frame)
            }
        }
        return result
    }
}

@Suite struct TerminalRingTests {
    private func append(_ ring: inout TerminalRing, _ text: String) {
        Array(text.utf8).withUnsafeBytes { ring.append($0) }
    }

    @Test func aReaderInsideTheRingMissesNothing() {
        var ring = TerminalRing(limit: 4096)
        append(&ring, "one\r\ntwo\r\n")
        #expect(ring.read(from: 5, limit: 100) == Data("two\r\n".utf8))
        #expect(ring.read(from: 10, limit: 100) == Data())
        #expect(ring.read(from: 11, limit: 100) == nil)
    }

    @Test func aReaderBehindTheRingIsStartedOverAtALine() {
        var ring = TerminalRing(limit: 4096)
        for index in 0..<2000 { append(&ring, "line \(index) \u{1b}[32mok\u{1b}[0m\r\n") }
        #expect(ring.read(from: 0, limit: 10) == nil)
        let replay = ring.replayStart()
        let text = String(decoding: ring.read(from: replay.offset, limit: 64) ?? Data(), as: UTF8.self)
        #expect(text.hasPrefix("line "))
        #expect(replay.offset >= ring.startOffset)
    }

    @Test func theModesALateReaderCannotGuessAreReplayed() {
        var ring = TerminalRing(limit: 4096)
        append(&ring, "\u{1b}[?1049h\u{1b}[?2004h\u{1b}[?25l\u{1b}=")
        append(&ring, String(repeating: "x", count: 9000))
        let preamble = String(decoding: ring.replayStart().preamble, as: UTF8.self)
        #expect(preamble.contains("\u{1b}[?1049h"))
        #expect(preamble.contains("\u{1b}[?2004h"))
        #expect(preamble.contains("\u{1b}[?25l"))
        #expect(preamble.hasSuffix("\u{1b}="))
    }

    @Test func aModeTurnedOffAgainIsReplayedOff() {
        var ring = TerminalRing(limit: 4096)
        append(&ring, "\u{1b}[?1049h\u{1b}[?1049l")
        append(&ring, String(repeating: "x", count: 9000))
        let preamble = String(decoding: ring.replayStart().preamble, as: UTF8.self)
        #expect(preamble.contains("\u{1b}[?1049l"))
        #expect(!preamble.contains("\u{1b}[?1049h"))
    }

    @Test func theStartNeverFallsInsideASequenceOrACharacter() {
        var ring = TerminalRing(limit: 4096)
        append(&ring, String(repeating: "\u{1b}[38;2;10;20;30mé", count: 2000))
        let replay = ring.replayStart()
        let bytes = [UInt8](ring.read(from: replay.offset, limit: 8) ?? Data())
        #expect(bytes.first == 0x1b || bytes.first == 0xc3)
    }
}

@Suite(.serialized) struct TerminalSeatTests {
    private func collect(
        _ seat: TerminalSeat, from offset: UInt64? = nil, until done: @escaping @Sendable (String) -> Bool,
        seconds: Double = 10
    ) async throws -> (text: String, frames: [TerminalFrame]) {
        let task = Task { () -> (String, [TerminalFrame]) in
            var reader = TerminalFrameReader()
            var text = ""
            var frames: [TerminalFrame] = []
            for await piece in seat.feed(from: offset) {
                for frame in try reader.read(piece) {
                    frames.append(frame)
                    if case .output(let data) = frame { text += String(decoding: data, as: UTF8.self) }
                    if case .exit = frame { return (text, frames) }
                }
                if done(text) { break }
            }
            return (text, frames)
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(seconds))
            task.cancel()
        }
        let result = try await task.value
        timeout.cancel()
        return result
    }

    private func open(_ hall: TerminalHall, directory: String? = nil) throws -> TerminalSeat {
        try hall.open(TerminalOpenRequest(directory: directory, session: "chat", cols: 100, rows: 30))
    }

    @Test func aShellAnswersWhatIsTyped() async throws {
        let hall = TerminalHall()
        defer { hall.closeAll() }
        let seat = try open(hall, directory: "/tmp")
        seat.send(Data("echo marker-$((6*7))\n".utf8))
        let result = try await collect(seat) { $0.contains("marker-42") }
        #expect(result.text.contains("marker-42"))
        guard case .start(let start)? = result.frames.first else {
            Issue.record("the first frame was not a start")
            return
        }
        #expect(start.reset)
        #expect(start.cols == 100 && start.rows == 30)
    }

    @Test func theShellHasAControllingTerminalOfTheSizeAsked() async throws {
        let hall = TerminalHall()
        defer { hall.closeAll() }
        let seat = try open(hall)
        seat.send(Data("stty size; tty; echo done-$((40+2))\n".utf8))
        let result = try await collect(seat) { $0.contains("done-42") }
        #expect(result.text.contains("30 100"))
        #expect(result.text.contains("/dev/"))
        #expect(!result.text.contains("not a tty"))
        seat.resize(cols: 132, rows: 43)
        seat.send(Data("stty size; echo again-$((40+2))\n".utf8))
        let later = try await collect(seat) { $0.contains("again-42") }
        #expect(later.text.contains("43 132"))
    }

    @Test func theFolderFollowsTheShellAndAJobIsNamed() async throws {
        let hall = TerminalHall()
        defer { hall.closeAll() }
        let seat = try open(hall, directory: "/tmp")
        #expect(seat.info().session == "chat")
        seat.send(Data("cd /usr && echo moved-$((40+2))\n".utf8))
        _ = try await collect(seat) { $0.contains("moved-42") }
        #expect(seat.info().directory == "/usr")
        #expect(seat.info().job == nil)
        #expect(hall.busyCount() == 0)
        seat.send(Data("sleep 30\n".utf8))
        var job: String?
        for _ in 0..<50 {
            job = seat.info().job
            if job != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(job == "sleep")
        #expect(hall.busyCount() == 1)
        seat.send(Data([0x03]))
        for _ in 0..<50 where seat.info().job != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(seat.info().job == nil)
    }

    @Test func aReaderThatComesBackGoesOnFromWhereItWas() async throws {
        let hall = TerminalHall()
        defer { hall.closeAll() }
        let seat = try open(hall)
        seat.send(Data("echo first-$((40+2))\n".utf8))
        let first = try await collect(seat) { $0.contains("first-42") }
        guard case .start(let start)? = first.frames.first else {
            Issue.record("no start frame")
            return
        }
        let reached = start.offset + UInt64(first.text.utf8.count)
        seat.send(Data("echo second-$((40+2))\n".utf8))
        let second = try await collect(seat, from: reached) { $0.contains("second-42") }
        guard case .start(let resumed)? = second.frames.first else {
            Issue.record("no start frame on return")
            return
        }
        #expect(!resumed.reset)
        #expect(resumed.offset == reached)
        #expect(!second.text.contains("first-42"))
        #expect(second.text.contains("second-42"))
    }

    @Test func aShellThatEndsSaysHow() async throws {
        let hall = TerminalHall()
        defer { hall.closeAll() }
        let seat = try open(hall)
        seat.send(Data("exit 7\n".utf8))
        let result = try await collect(seat) { _ in false }
        #expect(result.frames.last == .exit(TerminalExit(code: 7)))
        #expect(seat.info().exitCode == 7)
        #expect(!seat.isRunning)
    }

    @Test func closingHangsTheShellUp() async throws {
        let hall = TerminalHall()
        let seat = try open(hall)
        seat.send(Data("sleep 300\n".utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect(hall.close(seat.id))
        #expect(hall.seat(seat.id) == nil)
        let result = try await collect(seat) { _ in false }
        guard case .exit? = result.frames.last else {
            Issue.record("the shell did not end")
            return
        }
    }

    @Test func theLimitIsSaidInWords() throws {
        var policy = TerminalHall.Policy()
        policy.limit = 1
        let hall = TerminalHall(policy: policy)
        defer { hall.closeAll() }
        _ = try open(hall)
        #expect(throws: TerminalHostError.tooMany(1)) { _ = try open(hall) }
    }

    @Test func theServersSecretsStayWithTheServer() {
        let environment = ShellEnvironment.compose(
            base: ["BRIDGE_PASSWORD": "x", "PATH": "/bin", "NOTIFY_SOCKET": "/run/x"], shell: "/bin/sh",
            directory: "/tmp", scrubbing: ["BRIDGE_PASSWORD"])
        #expect(environment["BRIDGE_PASSWORD"] == nil)
        #expect(environment["NOTIFY_SOCKET"] == nil)
        #expect(environment["TERM"] == "xterm-256color")
        #expect(environment["PWD"] == "/tmp")
        #expect(environment["PATH"] == "/bin")
    }
}
