import AgentCore
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The shells an opencode 2 server holds, spoken in the terminal wire every client reads.
///
/// opencode keeps its pseudo-terminals in `/api/pty` and streams each over a WebSocket: output as
/// text frames counted in UTF-16 units, one binary frame (a zero byte, then `{"cursor": N}`) after
/// the replay, and input as frames sent back. A resize is a `PUT`. Everything the bridges say in
/// their own route (the start of the stream, its byte positions, the folder and the program in
/// front) is rebuilt here from that, so a client cannot tell which server holds its shell.
extension OpenCodeV2Backend: TerminalHostingBackend {
    var terminalHub: OpenCodeV2TerminalHub { OpenCodeV2TerminalHubRegistry.hub(for: client) }

    public func terminals() async throws -> [TerminalInfo] {
        let ptys = try await client.ptys()
        var infos: [TerminalInfo] = []
        for pty in ptys { infos.append(await terminalHub.info(for: pty)) }
        return infos
    }

    public func openTerminal(_ request: TerminalOpenRequest) async throws -> TerminalInfo {
        let title = OpenCodeV2TerminalHub.title(desk: request.desk)
        let pty: OC2Pty
        do {
            pty = try await client.createPty(cwd: request.directory, title: title)
        } catch let error as AgentError where request.directory != nil {
            guard case .http = error else { throw error }
            pty = try await client.createPty(cwd: nil, title: title)
        }
        let size = TerminalSize.clamped(cols: request.cols, rows: request.rows)
        try? await client.resizePty(pty.id, cols: size.cols, rows: size.rows)
        await terminalHub.sized(pty.id, cols: size.cols, rows: size.rows)
        return await terminalHub.info(for: pty)
    }

    public func terminal(_ id: String) async throws -> TerminalInfo? {
        do {
            return await terminalHub.info(for: try await client.pty(id))
        } catch let error as AgentError {
            if case .http(let status, _) = error, status == 404 { return nil }
            throw error
        }
    }

    public func terminalFrames(_ id: String, from offset: UInt64?) -> AsyncThrowingStream<TerminalFrame, Error> {
        let client = self.client
        let hub = terminalHub
        return AsyncThrowingStream { continuation in
            let task = Task {
                let reader = OpenCodeV2TerminalReader(id: id, client: client, hub: hub)
                do {
                    try await reader.run(from: offset) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func sendTerminalInput(_ id: String, bytes: Data) async throws {
        try await terminalHub.send(bytes, to: id)
    }

    public func resizeTerminal(_ id: String, cols: Int, rows: Int) async throws {
        try await client.resizePty(id, cols: cols, rows: rows)
        await terminalHub.sized(id, cols: cols, rows: rows)
    }

    public func closeTerminal(_ id: String) async throws {
        await terminalHub.forget(id)
        do {
            try await client.removePty(id)
        } catch let error as AgentError {
            if case .http(let status, _) = error, status == 404 { return }
            throw error
        }
    }
}

private struct OC2PtyCreate: Encodable {
    let cwd: String?
    let title: String
}

private struct OC2PtyResize: Encodable {
    struct Size: Encodable {
        let rows: Int
        let cols: Int
    }

    let size: Size
}

private struct OC2PtyCursor: Decodable {
    let cursor: Int
}

extension OpenCodeV2Client {
    private func ptyEnvelope<T: Decodable & Sendable>(_ data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(OC2Envelope<T>.self, from: data).data
        } catch {
            throw AgentError.decoding("\(T.self): \(error)")
        }
    }

    func ptys() async throws -> [OC2Pty] {
        try ptyEnvelope(await http.send(builder.request(.get, "/api/pty")))
    }

    func pty(_ id: String) async throws -> OC2Pty {
        try ptyEnvelope(await http.send(builder.request(.get, "/api/pty/\(id)")))
    }

    func createPty(cwd: String?, title: String) async throws -> OC2Pty {
        let body = try JSONEncoder().encode(OC2PtyCreate(cwd: cwd, title: title))
        return try ptyEnvelope(await http.send(builder.request(.post, "/api/pty", body: body)))
    }

    func resizePty(_ id: String, cols: Int, rows: Int) async throws {
        let size = TerminalSize.clamped(cols: cols, rows: rows)
        let body = try JSONEncoder().encode(OC2PtyResize(size: .init(rows: size.rows, cols: size.cols)))
        _ = try await http.send(builder.request(.put, "/api/pty/\(id)", body: body))
    }

    func removePty(_ id: String) async throws {
        _ = try await http.send(builder.request(.delete, "/api/pty/\(id)"))
    }

    /// The pty's socket. No cursor replays everything the server still holds.
    func ptySocketRequest(_ id: String, cursor: Int?) throws -> URLRequest {
        let query = cursor.map { [URLQueryItem(name: "cursor", value: String($0))] } ?? []
        var request = try builder.request(.get, "/api/pty/\(id)/connect", query: query)
        request.setValue(nil, forHTTPHeaderField: "Accept")
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw AgentError.invalidURL("/api/pty/\(id)/connect") }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        return request
    }
}

/// One process-wide hub per server, because backends are minted freely and a key typed into one
/// must leave through the socket another one opened.
enum OpenCodeV2TerminalHubRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hubs: [String: OpenCodeV2TerminalHub] = [:]

    static func hub(for client: OpenCodeV2Client) -> OpenCodeV2TerminalHub {
        let config = client.builder.config
        let key = config.baseURL.absoluteString + "|" + (config.credentials?.username ?? "")
            + ":" + (config.credentials?.password ?? "")
        return lock.withLock {
            if let existing = hubs[key] { return existing }
            let created = OpenCodeV2TerminalHub()
            hubs[key] = created
            return created
        }
    }
}

/// What this process knows about each pty that opencode does not say: the socket keys leave
/// through, the size last asked for, when it was first seen, where the shell stands and what runs
/// in front of it, and which byte position each UTF-16 cursor the server counts in stands at.
actor OpenCodeV2TerminalHub {
    static let titlePrefix = "Tailscode · "
    static let positionsKept = 64

    struct Position: Equatable, Sendable {
        var bytes: UInt64
        var cursor: Int
    }

    private struct Seat {
        var socket: URLSessionWebSocketTask?
        var socketID: UUID?
        var cols = 80
        var rows = 24
        var firstSeen = Date()
        var shell = ShellMarks()
        var positions: [Position] = []
        var inputTail = Data()
    }

    private var seats: [String: Seat] = [:]

    static func title(desk: String?) -> String {
        titlePrefix + (desk ?? "Terminal")
    }

    static func desk(fromTitle title: String?) -> String? {
        guard let title, title.hasPrefix(titlePrefix) else { return nil }
        let desk = String(title.dropFirst(titlePrefix.count))
        return desk.isEmpty ? nil : desk
    }

    private func seat(_ id: String) -> Seat {
        if let seat = seats[id] { return seat }
        let seat = Seat()
        seats[id] = seat
        return seat
    }

    func info(for pty: OC2Pty) -> TerminalInfo {
        let seat = seat(pty.id)
        let shell = pty.command.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? "sh"
        return TerminalInfo(
            id: pty.id, shell: shell, directory: seat.shell.directory ?? pty.cwd,
            job: pty.hasExited ? nil : seat.shell.job, cols: seat.cols, rows: seat.rows,
            startedAt: seat.firstSeen, desk: Self.desk(fromTitle: pty.title),
            exitCode: pty.hasExited ? (pty.exitCode ?? 0) : nil)
    }

    func sized(_ id: String, cols: Int, rows: Int) {
        var seat = seat(id)
        let size = TerminalSize.clamped(cols: cols, rows: rows)
        seat.cols = size.cols
        seat.rows = size.rows
        seats[id] = seat
    }

    func size(_ id: String) -> (cols: Int, rows: Int) {
        let seat = seat(id)
        return (seat.cols, seat.rows)
    }

    func marks(_ id: String) -> ShellMarks { seat(id).shell }

    func record(_ marks: ShellMarks, for id: String) {
        seats[id]?.shell = marks
    }

    /// The server cursor a client standing at `bytes` continues from, when this process handed
    /// it that position.
    func cursor(at bytes: UInt64, for id: String) -> Int? {
        seats[id]?.positions.last { $0.bytes == bytes }?.cursor
    }

    func reached(_ position: Position, for id: String) {
        guard var seat = seats[id] else { return }
        seat.positions.append(position)
        if seat.positions.count > Self.positionsKept {
            seat.positions.removeFirst(seat.positions.count - Self.positionsKept)
        }
        seats[id] = seat
    }

    func attach(_ socket: URLSessionWebSocketTask, as socketID: UUID, to id: String) {
        var seat = seat(id)
        seat.socket = socket
        seat.socketID = socketID
        seats[id] = seat
    }

    func detach(_ socketID: UUID, from id: String) {
        guard seats[id]?.socketID == socketID else { return }
        seats[id]?.socket = nil
        seats[id]?.socketID = nil
    }

    func forget(_ id: String) {
        seats[id]?.socket?.cancel(with: .goingAway, reason: nil)
        seats[id] = nil
    }

    /// Keys leave through the socket the terminal is being read on. The server reads a frame as
    /// UTF-8 and drops one that is not, so a character cut in two by the link's pieces waits for
    /// its other half. With no socket open, the link is told to try again: its reader is
    /// reconnecting.
    func send(_ bytes: Data, to id: String) async throws {
        guard var seat = seats[id], let socket = seat.socket else {
            throw AgentError.connection("The terminal is reconnecting.")
        }
        var pending = seat.inputTail
        pending.append(bytes)
        let whole = UTF8Count.wholeCharacterPrefix(of: pending)
        seat.inputTail = Data(pending.suffix(from: pending.startIndex + whole))
        seats[id] = seat
        guard whole > 0 else { return }
        let text = String(decoding: pending.prefix(whole), as: UTF8.self)
        do {
            try await socket.send(.string(text))
        } catch {
            seats[id]?.inputTail = pending
            throw AgentError.connection("The terminal is reconnecting.")
        }
    }
}

/// UTF-8 bytes measured the way opencode measures its output: in UTF-16 units.
enum UTF8Count {
    /// How many UTF-16 units `bytes` add, read one byte at a time so a character cut between two
    /// pieces is counted once, by its lead byte.
    static func utf16Units(in bytes: Data) -> Int {
        var units = 0
        for byte in bytes {
            if byte & 0xC0 == 0x80 { continue }
            units += byte >= 0xF0 ? 2 : 1
        }
        return units
    }

    /// The length of the longest prefix that does not end inside a character.
    static func wholeCharacterPrefix(of bytes: Data) -> Int {
        let count = bytes.count
        var index = count
        var back = 0
        while index > 0, back < 4 {
            index -= 1
            back += 1
            let byte = bytes[bytes.startIndex + index]
            if byte & 0xC0 == 0x80 { continue }
            let length: Int
            switch byte {
            case 0xF0...: length = 4
            case 0xE0...: length = 3
            case 0xC0...: length = 2
            default: length = 1
            }
            return back >= length ? count : index
        }
        return count
    }
}

/// One read of a pty's socket, turned into the framed stream a ``TerminalLink`` reads.
struct OpenCodeV2TerminalReader {
    let id: String
    let client: OpenCodeV2Client
    let hub: OpenCodeV2TerminalHub

    static let pingEvery: Duration = .seconds(20)
    static let replayLimit = 8 << 20

    func run(from offset: UInt64?, yield: @Sendable @escaping (TerminalFrame) -> Void) async throws {
        let resume: (bytes: UInt64, cursor: Int)? = await {
            guard let offset, let cursor = await hub.cursor(at: offset, for: id) else { return nil }
            return (offset, cursor)
        }()
        let socket = URLSession.shared.webSocketTask(with: try client.ptySocketRequest(id, cursor: resume?.cursor))
        let socketID = UUID()
        socket.resume()
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingEvery)
                if Task.isCancelled { return }
                if await !Self.answered(socket) {
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer {
            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
        }
        try await withTaskCancellationHandler {
            try await read(socket, socketID: socketID, resume: resume, yield: yield)
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
        await hub.detach(socketID, from: id)
    }

    private func read(
        _ socket: URLSessionWebSocketTask, socketID: UUID, resume: (bytes: UInt64, cursor: Int)?,
        yield: @Sendable @escaping (TerminalFrame) -> Void
    ) async throws {
        var replay = Data()
        var replayUnits = 0
        var started = false
        var position = OpenCodeV2TerminalHub.Position(bytes: 0, cursor: 0)
        var marks = await hub.marks(id)
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                await hub.detach(socketID, from: id)
                if Task.isCancelled { return }
                try await settle(after: error, yield: yield)
                return
            }
            let bytes: Data
            switch message {
            case .string(let text):
                bytes = Data(text.utf8)
            case .data(let data):
                if !started, let cursor = Self.metaCursor(data) {
                    let size = await hub.size(id)
                    let start = cursor - replayUnits
                    let reset: Bool
                    if let resume, start == resume.cursor {
                        position = .init(bytes: resume.bytes, cursor: start)
                        reset = false
                    } else {
                        position = .init(bytes: resume?.bytes ?? UInt64(max(start, 0)), cursor: start)
                        reset = true
                        marks = await hub.marks(id).restarted()
                    }
                    yield(.start(TerminalStart(offset: position.bytes, reset: reset, cols: size.cols, rows: size.rows)))
                    started = true
                    await hub.attach(socket, as: socketID, to: id)
                    await hub.reached(position, for: id)
                    if !replay.isEmpty {
                        deliver(replay, units: replayUnits, position: &position, marks: &marks, yield: yield)
                        await hub.reached(position, for: id)
                        replay = Data()
                    }
                    await publish(marks, yield: yield)
                    continue
                }
                bytes = data
            @unknown default:
                continue
            }
            let units = UTF8Count.utf16Units(in: bytes)
            guard started else {
                guard replay.count + bytes.count <= Self.replayLimit else {
                    throw AgentError.server("The terminal's replay is larger than any opencode holds.")
                }
                replay.append(bytes)
                replayUnits += units
                continue
            }
            let before = marks
            deliver(bytes, units: units, position: &position, marks: &marks, yield: yield)
            await hub.reached(position, for: id)
            if marks.reading != before.reading { await publish(marks, yield: yield) }
        }
    }

    private func deliver(
        _ bytes: Data, units: Int, position: inout OpenCodeV2TerminalHub.Position, marks: inout ShellMarks,
        yield: (TerminalFrame) -> Void
    ) {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = bytes.index(index, offsetBy: 64 << 10, limitedBy: bytes.endIndex) ?? bytes.endIndex
            yield(.output(Data(bytes[index..<end])))
            index = end
        }
        marks.read(bytes)
        position.bytes += UInt64(bytes.count)
        position.cursor += units
    }

    private func publish(_ marks: ShellMarks, yield: (TerminalFrame) -> Void) async {
        await hub.record(marks, for: id)
        guard let pty = try? await client.pty(id) else { return }
        yield(.state(await hub.info(for: pty)))
    }

    /// The socket closed: the shell ended, the server let the terminal go, or the connection
    /// dropped. The server's record says which.
    private func settle(after error: Error, yield: (TerminalFrame) -> Void) async throws {
        let pty: OC2Pty
        do {
            pty = try await client.pty(id)
        } catch let failure as AgentError {
            if case .http(let status, _) = failure, status == 404 { throw failure }
            throw error
        }
        if pty.hasExited {
            yield(.exit(TerminalExit(code: pty.exitCode)))
            return
        }
        throw error
    }

    static func metaCursor(_ data: Data) -> Int? {
        guard data.first == 0, data.count > 1, data.count < 256 else { return nil }
        return (try? JSONDecoder().decode(OC2PtyCursor.self, from: data.dropFirst()))?.cursor
    }

    /// Whether the server answers a ping within fifteen seconds. The answer is read after the
    /// wait rather than awaited, so a ping Foundation never calls back cannot hold the reader.
    private static func answered(_ socket: URLSessionWebSocketTask) async -> Bool {
        let pong = Pong()
        socket.sendPing { error in if error == nil { pong.heard() } }
        try? await Task.sleep(for: .seconds(15))
        return pong.wasHeard
    }
}

private final class Pong: @unchecked Sendable {
    private let lock = NSLock()
    private var answered = false

    func heard() { lock.withLock { answered = true } }

    var wasHeard: Bool { lock.withLock { answered } }
}
