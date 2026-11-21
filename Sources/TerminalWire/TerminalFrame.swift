import Foundation

/// One piece of a terminal's output stream.
///
/// The stream is binary and framed: a kind byte, a four-byte big-endian length, then that many
/// bytes. Output is the shell's own bytes, untouched; everything else is a small JSON object. A
/// reader that does not know a kind skips its bytes, so a newer server can say more without
/// breaking an older client.
public enum TerminalFrame: Sendable, Equatable {
    /// Always first. Where the output that follows begins, and whether the reader's own screen
    /// can still be trusted.
    case start(TerminalStart)
    case output(Data)
    /// The server's reading of the terminal changed: its folder, the program in front, its size.
    case state(TerminalInfo)
    /// The shell ended. Nothing follows.
    case exit(TerminalExit)
    /// Nothing happened, sent so a reader can tell a quiet shell from a dead connection.
    case ping

    public static let headerLength = 5
    /// A frame longer than this is not a frame: the reader has lost its place in the stream.
    public static let maximumLength = 8 << 20

    enum Kind: UInt8 {
        case start = 1
        case output = 2
        case state = 3
        case exit = 4
        case ping = 5
    }
}

public struct TerminalStart: Codable, Sendable, Equatable {
    /// The position, counted in bytes since the shell started, of the first output byte that
    /// follows.
    public var offset: UInt64
    /// True when what follows does not continue what the reader last saw: the reader asked for
    /// nothing in particular, or for output the server no longer holds. The reader clears its
    /// screen and its scrollback before drawing what follows, which begins with the modes the
    /// terminal was in at that point.
    public var reset: Bool
    public var cols: Int
    public var rows: Int

    public init(offset: UInt64, reset: Bool, cols: Int, rows: Int) {
        self.offset = offset
        self.reset = reset
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalExit: Codable, Sendable, Equatable {
    /// The shell's exit status, as a shell reports one: 128 plus the signal for a shell that was
    /// killed. Absent when the server never learned it.
    public var code: Int?

    public init(code: Int?) {
        self.code = code
    }
}

extension TerminalFrame {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The frame as it travels.
    public func encoded() -> Data {
        switch self {
        case .start(let start): return Self.frame(.start, Self.json(start))
        case .output(let bytes): return Self.frame(.output, bytes)
        case .state(let info): return Self.frame(.state, Self.json(info))
        case .exit(let exit): return Self.frame(.exit, Self.json(exit))
        case .ping: return Self.frame(.ping, Data())
        }
    }

    private static func json<T: Encodable>(_ value: T) -> Data {
        (try? encoder.encode(value)) ?? Data("{}".utf8)
    }

    private static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var data = Data(capacity: headerLength + payload.count)
        data.append(kind.rawValue)
        let length = UInt32(payload.count)
        data.append(UInt8(truncatingIfNeeded: length >> 24))
        data.append(UInt8(truncatingIfNeeded: length >> 16))
        data.append(UInt8(truncatingIfNeeded: length >> 8))
        data.append(UInt8(truncatingIfNeeded: length))
        data.append(payload)
        return data
    }

    static func decode(kind: UInt8, payload: Data) -> TerminalFrame? {
        switch Kind(rawValue: kind) {
        case .start: return (try? decoder.decode(TerminalStart.self, from: payload)).map(TerminalFrame.start)
        case .output: return .output(payload)
        case .state: return (try? decoder.decode(TerminalInfo.self, from: payload)).map(TerminalFrame.state)
        case .exit: return .exit((try? decoder.decode(TerminalExit.self, from: payload)) ?? TerminalExit(code: nil))
        case .ping: return .ping
        case nil: return nil
        }
    }
}

/// Reads frames out of a stream that arrives in pieces of any size.
///
/// A transport hands over whatever it has: half a header, three frames and the start of a fourth,
/// one frame cut into sixteen-kilobyte pieces. The reader keeps what is incomplete and returns
/// every frame that is whole. Output is handed on as it arrives rather than held until its frame
/// is complete, because a shell's bytes mean the same thing in any grouping and a megabyte of
/// them should reach the screen as they come.
public struct TerminalFrameReader: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// A length no frame has: the stream is not a terminal stream, or the reader lost its place.
        case malformed
    }

    private var pending = Data()
    private var streamingOutput = 0

    public init() {}

    public mutating func read(_ chunk: Data) throws -> [TerminalFrame] {
        var frames: [TerminalFrame] = []
        var input = chunk[...]
        if streamingOutput > 0 {
            let taken = input.prefix(streamingOutput)
            if !taken.isEmpty { frames.append(.output(Data(taken))) }
            streamingOutput -= taken.count
            input = input.dropFirst(taken.count)
            if input.isEmpty { return frames }
        }
        pending.append(contentsOf: input)
        while pending.count >= TerminalFrame.headerLength {
            let base = pending.startIndex
            let kind = pending[base]
            let length =
                Int(pending[base + 1]) << 24 | Int(pending[base + 2]) << 16
                | Int(pending[base + 3]) << 8 | Int(pending[base + 4])
            guard length <= TerminalFrame.maximumLength else { throw Failure.malformed }
            let available = pending.count - TerminalFrame.headerLength
            if kind == TerminalFrame.Kind.output.rawValue {
                let taken = min(available, length)
                if taken > 0 {
                    let start = base + TerminalFrame.headerLength
                    frames.append(.output(Data(pending[start..<(start + taken)])))
                }
                streamingOutput = length - taken
                pending = Data(pending.dropFirst(TerminalFrame.headerLength + taken))
                continue
            }
            guard available >= length else { break }
            let start = base + TerminalFrame.headerLength
            let payload = Data(pending[start..<(start + length)])
            pending = Data(pending.dropFirst(TerminalFrame.headerLength + length))
            if let frame = TerminalFrame.decode(kind: kind, payload: payload) { frames.append(frame) }
        }
        return frames
    }
}
