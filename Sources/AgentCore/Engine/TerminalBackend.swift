import Foundation
@_exported import TerminalWire

/// A backend whose server holds shells for its clients.
///
/// The shell lives on the machine the agent works on, in the folder the agent works in, and
/// belongs to the server: closing the app, losing the connection or picking up another device
/// leaves it running, and coming back finds it as it was. That is also the only shape that works
/// for a client that may not start a process of its own, such as a sandboxed app or a phone.
public protocol TerminalHostingBackend: CodingAgentBackend {
    func terminals() async throws -> [TerminalInfo]
    func openTerminal(_ request: TerminalOpenRequest) async throws -> TerminalInfo
    /// The server's reading of one terminal, nil when it holds no such terminal.
    func terminal(_ id: String) async throws -> TerminalInfo?
    /// The terminal's output from `offset` on. No offset, or one the server no longer holds,
    /// starts with a frame that says the reader must start over.
    func terminalFrames(_ id: String, from offset: UInt64?) -> AsyncThrowingStream<TerminalFrame, Error>
    func sendTerminalInput(_ id: String, bytes: Data) async throws
    func resizeTerminal(_ id: String, cols: Int, rows: Int) async throws
    func closeTerminal(_ id: String) async throws
}

/// One client's hold on one terminal.
///
/// It keeps the hold through everything a connection does: a stream that drops is asked for again
/// from the byte it reached, so nothing is drawn twice and nothing is missed; keys are sent in the
/// order they were pressed, a few at a time when the connection is slower than the hands; and a
/// window dragged through fifty sizes asks the server for the last one.
public actor TerminalLink {
    public enum Event: Sendable, Equatable {
        /// The shell's bytes, in order, each exactly once.
        case output(Data)
        /// What follows does not continue what came before: clear the screen and the scrollback.
        case reset(cols: Int, rows: Int)
        case state(TerminalInfo)
        case connection(Connection)
        /// The shell ended. Nothing follows.
        case ended(code: Int?)
        /// The server no longer holds this terminal: it restarted, or the terminal was closed
        /// from somewhere else. Nothing follows.
        case gone
    }

    public enum Connection: Sendable, Equatable {
        case connecting
        case live
        /// The stream dropped and is being asked for again.
        case waiting
    }

    public nonisolated let id: String
    public nonisolated let events: AsyncStream<Event>

    private let backend: any TerminalHostingBackend
    private let continuation: AsyncStream<Event>.Continuation
    private var offset: UInt64?
    private var reader: Task<Void, Never>?
    private var finished = false
    private var pendingInput = Data()
    private var sender: Task<Void, Never>?
    private var wantedSize: TerminalResizeRequest?
    private var sentSize: TerminalResizeRequest?
    private var resizer: Task<Void, Never>?

    static let inputBacklog = 4 << 20
    static let inputPiece = 64 << 10

    /// - Parameter offset: where this client's screen already stands, for a client that kept its
    ///   screen across a break. Nil for a client with an empty screen.
    public init(backend: any TerminalHostingBackend, id: String, from offset: UInt64? = nil) {
        self.backend = backend
        self.id = id
        self.offset = offset
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    public func start() {
        guard reader == nil, !finished else { return }
        reader = Task { await read() }
    }

    private func read() async {
        var delay = 0.25
        var first = true
        while !Task.isCancelled, !finished {
            continuation.yield(.connection(first ? .connecting : .waiting))
            first = false
            do {
                for try await frame in backend.terminalFrames(id, from: offset) {
                    if finished { return }
                    switch frame {
                    case .start(let start):
                        if start.reset { continuation.yield(.reset(cols: start.cols, rows: start.rows)) }
                        offset = start.offset
                        delay = 0.25
                        continuation.yield(.connection(.live))
                    case .output(let bytes):
                        offset = (offset ?? 0) + UInt64(bytes.count)
                        continuation.yield(.output(bytes))
                    case .state(let info):
                        continuation.yield(.state(info))
                    case .exit(let exit):
                        finish(.ended(code: exit.code))
                        return
                    case .ping:
                        break
                    }
                }
            } catch let error as AgentError {
                if case .http(let status, _) = error, status == 404 || status == 410 {
                    finish(.gone)
                    return
                }
            } catch {}
            if Task.isCancelled || finished { return }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 5)
        }
    }

    private func finish(_ event: Event?) {
        guard !finished else { return }
        finished = true
        if let event { continuation.yield(event) }
        continuation.finish()
        reader?.cancel()
        sender?.cancel()
        resizer?.cancel()
    }

    /// What the person typed or pasted. Order is kept; a connection slower than the typing sends
    /// several keys in one request rather than one request behind another.
    public func send(_ bytes: Data) {
        guard !finished, !bytes.isEmpty, pendingInput.count + bytes.count <= Self.inputBacklog else { return }
        pendingInput.append(bytes)
        guard sender == nil else { return }
        sender = Task { await drainInput() }
    }

    private func drainInput() async {
        var failures = 0
        while !pendingInput.isEmpty, !finished, !Task.isCancelled {
            let piece = Data(pendingInput.prefix(Self.inputPiece))
            do {
                try await backend.sendTerminalInput(id, bytes: piece)
                pendingInput.removeFirst(min(piece.count, pendingInput.count))
                failures = 0
            } catch let error as AgentError {
                if case .http(let status, _) = error, (400..<500).contains(status) {
                    pendingInput.removeAll()
                    break
                }
                failures += 1
            } catch {
                failures += 1
            }
            if failures > 0 {
                if failures > 20 {
                    pendingInput.removeAll()
                    break
                }
                try? await Task.sleep(for: .milliseconds(min(150 * failures, 1500)))
            }
        }
        sender = nil
    }

    /// The size the screen is now. Only the latest size asked for is sent.
    public func resize(cols: Int, rows: Int) {
        let size = TerminalSize.clamped(cols: cols, rows: rows)
        let wanted = TerminalResizeRequest(cols: size.cols, rows: size.rows)
        guard !finished, wanted != wantedSize else { return }
        wantedSize = wanted
        guard resizer == nil else { return }
        resizer = Task { await drainResize() }
    }

    private func drainResize() async {
        var failures = 0
        while let wanted = wantedSize, wanted != sentSize, !finished, !Task.isCancelled, failures < 6 {
            do {
                try await backend.resizeTerminal(id, cols: wanted.cols, rows: wanted.rows)
                sentSize = wanted
            } catch {
                failures += 1
                try? await Task.sleep(for: .milliseconds(300 * failures))
            }
        }
        resizer = nil
    }

    /// The position this client's screen stands at, for a client that will keep the screen and
    /// come back with a new link.
    public var position: UInt64? { offset }

    /// Lets go of the terminal and leaves it running on its server.
    public func detach() {
        finish(nil)
    }

    /// Ends the shell on its server.
    public func close() async {
        finish(nil)
        try? await backend.closeTerminal(id)
    }
}
