import Foundation

/// Follows a terminal's output just closely enough to know two things at any byte: whether that
/// byte is a safe place to start reading from, and which of the modes a late reader cannot guess
/// were on.
///
/// A server that kept a whole screen for every shell would be running a terminal emulator per
/// shell. This keeps a few dozen bytes instead. A reader who joins late is handed the modes as
/// they stood where the kept output begins, then the kept output, and a full-screen program is
/// asked to draw again; everything else a late reader could miss is repainted by the next thing
/// the program draws.
struct EscapeScanner: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case control
        case string
        case stringEscape
    }

    private static let remembered: Set<Int> = [
        1, 6, 7, 25, 47, 66, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1016, 1047, 1049, 2004,
    ]

    private var state = State.ground
    private var continuation = 0
    private var isPrivate = false
    private var parameters: [Int] = []
    private var parameter: Int?
    private var overflowed = false
    private var modes: [Int: Bool] = [:]
    private var keypadApplication = false

    /// Whether the stream stands between sequences and between characters: nothing read so far
    /// is the first half of something.
    var isGround: Bool {
        if case .ground = state { return continuation == 0 }
        return false
    }

    mutating func feed(_ bytes: UnsafeRawBufferPointer) {
        for byte in bytes { feed(byte) }
    }

    mutating func feed(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1b {
                state = .escape
                continuation = 0
            } else if byte >= 0xc0 {
                continuation = byte >= 0xf0 ? 3 : byte >= 0xe0 ? 2 : 1
            } else if byte >= 0x80 {
                if continuation > 0 { continuation -= 1 }
            } else {
                continuation = 0
            }
        case .escape:
            switch byte {
            case UInt8(ascii: "["):
                state = .control
                isPrivate = false
                parameters.removeAll(keepingCapacity: true)
                parameter = nil
                overflowed = false
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "_"), UInt8(ascii: "^"), UInt8(ascii: "X"):
                state = .string
            case UInt8(ascii: "="):
                keypadApplication = true
                state = .ground
            case UInt8(ascii: ">"):
                keypadApplication = false
                state = .ground
            case UInt8(ascii: "c"):
                modes.removeAll()
                keypadApplication = false
                state = .ground
            case 0x20...0x2f:
                break
            case 0x1b:
                break
            default:
                state = .ground
            }
        case .control:
            switch byte {
            case UInt8(ascii: "?"):
                if parameters.isEmpty, parameter == nil { isPrivate = true } else { overflowed = true }
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                let next = (parameter ?? 0) &* 10 &+ Int(byte - UInt8(ascii: "0"))
                parameter = min(next, 100_000)
            case UInt8(ascii: ";"), UInt8(ascii: ":"):
                push()
            case 0x3c...0x3f, 0x20...0x2f:
                overflowed = true
            case 0x40...0x7e:
                push()
                if isPrivate, !overflowed, byte == UInt8(ascii: "h") || byte == UInt8(ascii: "l") {
                    for mode in parameters where Self.remembered.contains(mode) {
                        modes[mode] = byte == UInt8(ascii: "h")
                    }
                }
                state = .ground
            case 0x1b:
                state = .escape
            default:
                break
            }
        case .string:
            if byte == 0x07 {
                state = .ground
            } else if byte == 0x1b {
                state = .stringEscape
            }
        case .stringEscape:
            state = byte == UInt8(ascii: "\\") ? .ground : byte == 0x1b ? .stringEscape : .string
        }
    }

    private mutating func push() {
        if let parameter {
            if parameters.count < 16 { parameters.append(parameter) } else { overflowed = true }
        }
        parameter = nil
    }

    /// The sequences that put a fresh terminal into the modes this one is in.
    func preamble() -> Data {
        var text = ""
        for mode in modes.keys.sorted() {
            guard let on = modes[mode] else { continue }
            text += "\u{1b}[?\(mode)\(on ? "h" : "l")"
        }
        if keypadApplication { text += "\u{1b}=" }
        return Data(text.utf8)
    }
}
