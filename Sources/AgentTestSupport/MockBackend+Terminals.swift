import AgentCore
import Foundation

/// What a mock server's shells know: where they start, what `ls` shows there, and what a few
/// commands print. Everything else is a command the shell has never heard of.
public struct MockTerminalWorld: Sendable {
    public var directory: String
    public var files: [String]
    /// A command line, exactly as typed, and what it prints.
    public var answers: [String: String]

    public init(
        directory: String = "/home/demo/project",
        files: [String] = ["Package.swift", "README.md", "Sources", "Tests"],
        answers: [String: String] = [:]
    ) {
        self.directory = directory
        self.files = files
        self.answers = answers
    }
}

/// A shell with no machine under it: it echoes what is typed, edits a line, and answers a handful
/// of commands, which is enough for a demo to type into and for a test to prove that a key
/// reached the server and its echo came back.
final class MockShell: @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private let world: MockTerminalWorld
    private let session: String?
    private let desk: String?
    private let startedAt = Date()
    private var directory: String
    private var cols: Int
    private var rows: Int
    private var log = Data()
    private var line = [UInt8]()
    private var skippingEscape = false
    private var exitCode: Int?
    private var readers: [UUID: AsyncThrowingStream<TerminalFrame, Error>.Continuation] = [:]

    init(id: String, request: TerminalOpenRequest, world: MockTerminalWorld) {
        self.id = id
        self.world = world
        self.session = request.session
        self.desk = request.desk
        self.directory = request.directory ?? world.directory
        self.cols = request.cols
        self.rows = request.rows
        emit(prompt())
    }

    var info: TerminalInfo {
        lock.withLock {
            TerminalInfo(
                id: id, shell: "bash", directory: exitCode == nil ? directory : nil, cols: cols, rows: rows,
                startedAt: startedAt, session: session, desk: desk, exitCode: exitCode,
                attached: readers.count,
                offset: UInt64(log.count))
        }
    }

    private func prompt() -> String {
        "\u{1b}[1;34m\((directory as NSString).lastPathComponent)\u{1b}[0m \u{1b}[32m❯\u{1b}[0m "
    }

    private func emit(_ text: String) {
        let bytes = Data(text.utf8)
        let listening: [AsyncThrowingStream<TerminalFrame, Error>.Continuation] = lock.withLock {
            log.append(bytes)
            return Array(readers.values)
        }
        for reader in listening { reader.yield(.output(bytes)) }
    }

    func frames(from offset: UInt64?) -> AsyncThrowingStream<TerminalFrame, Error> {
        AsyncThrowingStream { continuation in
            let key = UUID()
            lock.withLock {
                let held = UInt64(log.count)
                let from = offset.flatMap { $0 <= held ? $0 : nil }
                continuation.yield(
                    .start(TerminalStart(offset: from ?? 0, reset: from == nil, cols: cols, rows: rows)))
                continuation.yield(
                    .state(
                        TerminalInfo(
                            id: id, shell: "bash", directory: exitCode == nil ? directory : nil, cols: cols,
                            rows: rows, startedAt: startedAt, session: session, desk: desk, exitCode: exitCode,
                            attached: readers.count + 1, offset: held)))
                let backlog = log.dropFirst(Int(from ?? 0))
                if !backlog.isEmpty { continuation.yield(.output(Data(backlog))) }
                if let exitCode {
                    continuation.yield(.exit(TerminalExit(code: exitCode)))
                    continuation.finish()
                } else {
                    readers[key] = continuation
                }
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.readers.removeValue(forKey: key) }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        lock.withLock {
            self.cols = cols
            self.rows = rows
        }
    }

    func end(code: Int = 129) {
        let listening: [AsyncThrowingStream<TerminalFrame, Error>.Continuation] = lock.withLock {
            guard exitCode == nil else { return [] }
            exitCode = code
            let all = Array(readers.values)
            readers.removeAll()
            return all
        }
        for reader in listening {
            reader.yield(.exit(TerminalExit(code: code)))
            reader.finish()
        }
    }

    func vanish() {
        let listening: [AsyncThrowingStream<TerminalFrame, Error>.Continuation] = lock.withLock {
            exitCode = exitCode ?? 129
            let all = Array(readers.values)
            readers.removeAll()
            return all
        }
        for reader in listening { reader.finish() }
    }

    func type(_ bytes: Data) {
        for byte in bytes {
            guard lock.withLock({ exitCode == nil }) else { return }
            if skippingEscape {
                if (0x40...0x7e).contains(byte), byte != UInt8(ascii: "["), byte != UInt8(ascii: "O") {
                    skippingEscape = false
                }
                continue
            }
            switch byte {
            case 0x1b:
                skippingEscape = true
            case 0x0d, 0x0a:
                let command = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
                line.removeAll()
                emit("\r\n")
                run(command)
            case 0x7f, 0x08:
                guard !line.isEmpty else { continue }
                var removed = line.removeLast()
                while removed & 0xc0 == 0x80, !line.isEmpty { removed = line.removeLast() }
                emit("\u{8} \u{8}")
            case 0x03:
                line.removeAll()
                emit("^C\r\n" + prompt())
            case 0x04:
                if line.isEmpty { end(code: 0) }
            case 0x0c:
                emit("\u{1b}[H\u{1b}[2J" + prompt() + String(decoding: line, as: UTF8.self))
            case 0x20...:
                line.append(byte)
                echo(byte)
            default:
                break
            }
        }
    }

    private var echoPending = [UInt8]()

    /// Echoes a character once all of its bytes have arrived, so a letter with an accent is one
    /// write and not two halves.
    private func echo(_ byte: UInt8) {
        echoPending.append(byte)
        guard String(validating: echoPending, as: UTF8.self) != nil else {
            if echoPending.count > 4 { echoPending.removeAll() }
            return
        }
        let text = String(decoding: echoPending, as: UTF8.self)
        echoPending.removeAll()
        emit(text)
    }

    /// Tells every reader where the shell stands now, the way a server does once a second.
    private func announce() {
        let reading = info
        let listening = lock.withLock { Array(readers.values) }
        for reader in listening { reader.yield(.state(reading)) }
    }

    private func run(_ command: String) {
        defer {
            if lock.withLock({ exitCode == nil }) {
                emit(prompt())
                announce()
            }
        }
        guard !command.isEmpty else { return }
        if let answer = world.answers[command] {
            emit(answer.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n")
            return
        }
        let words = command.split(separator: " ").map(String.init)
        switch words[0] {
        case "pwd":
            emit(directory + "\r\n")
        case "ls":
            emit(world.files.joined(separator: "  ") + "\r\n")
        case "echo":
            emit(words.dropFirst().joined(separator: " ") + "\r\n")
        case "whoami":
            emit("demo\r\n")
        case "clear":
            emit("\u{1b}[H\u{1b}[2J")
        case "cd":
            let named = words.dropFirst().first { $0 != "--" } ?? "~"
            let target = named.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if target == "~" {
                directory = "/home/demo"
            } else if target == ".." {
                directory = (directory as NSString).deletingLastPathComponent
            } else if target.hasPrefix("/") {
                directory = target
            } else {
                directory = (directory as NSString).appendingPathComponent(target)
            }
        case "exit":
            end(code: words.count > 1 ? Int(words[1]) ?? 0 : 0)
        default:
            emit("bash: \(words[0]): command not found\r\n")
        }
    }
}

extension MockBackend: TerminalHostingBackend {
    public func terminals() async throws -> [TerminalInfo] {
        withMachine { $0.shells.values.map(\.info) }.sorted { $0.startedAt < $1.startedAt }
    }

    public func openTerminal(_ request: TerminalOpenRequest) async throws -> TerminalInfo {
        let shell = MockShell(id: UUID().uuidString.lowercased(), request: request, world: terminalWorld)
        withMachine { $0.shells[shell.id] = shell }
        return shell.info
    }

    public func terminal(_ id: String) async throws -> TerminalInfo? {
        withMachine { $0.shells[id] }?.info
    }

    public func terminalFrames(_ id: String, from offset: UInt64?) -> AsyncThrowingStream<TerminalFrame, Error> {
        guard let shell = withMachine({ $0.shells[id] }) else {
            return AsyncThrowingStream { $0.finish(throwing: AgentError.http(status: 404, body: "")) }
        }
        return shell.frames(from: offset)
    }

    public func sendTerminalInput(_ id: String, bytes: Data) async throws {
        guard let shell = withMachine({ $0.shells[id] }) else { throw AgentError.http(status: 404, body: "") }
        shell.type(bytes)
    }

    public func resizeTerminal(_ id: String, cols: Int, rows: Int) async throws {
        withMachine { $0.shells[id] }?.resize(cols: cols, rows: rows)
    }

    public func closeTerminal(_ id: String) async throws {
        withMachine { $0.shells.removeValue(forKey: id) }?.end()
    }

    /// Forgets a terminal the way a server that restarted has: its readers are cut off without
    /// being told how it ended, and asking for it again answers that it is gone.
    public func forgetTerminal(_ id: String) {
        withMachine { $0.shells.removeValue(forKey: id) }?.vanish()
    }
}
