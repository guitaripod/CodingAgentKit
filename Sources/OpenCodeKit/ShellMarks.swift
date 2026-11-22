import Foundation

/// Where a shell stands and what runs in front of it, read from what the shell says in its own
/// output, for a server that does not say it.
///
/// A shell set up for it marks its prompts and commands: systemd's context marks (OSC 3008, which
/// Arch and Fedora's bash print by default), FinalTerm's prompt marks (OSC 133) and the folder a
/// prompt stands in (OSC 7, iTerm's OSC 1337). Once a shell has marked anything, only its marks
/// decide whether a program is in front. A shell that marks nothing is read by its screen: a
/// program that takes the alternate screen (an editor, a pager, a monitor) is in front until it
/// gives it back, and anything else is taken to be the shell at its prompt. A program's name is
/// the first word of the line the shell echoed when Return was pressed.
struct ShellMarks: Sendable {
    struct Reading: Sendable, Equatable {
        var directory: String?
        var job: String?
    }

    private enum State: Sendable {
        case ground
        case escape
        case osc
        case oscEscape
        case csi
    }

    private(set) var reading = Reading()
    private var marked = false
    private var alternate = false
    private var state = State.ground
    private var payload: [UInt8] = []
    private var line: [UInt8] = []
    private var commandStart: Int?
    private var lastLine: [UInt8] = []
    private var lastLineIsCommand = false
    private var commands: Set<String> = []

    static let payloadLimit = 4096
    static let lineLimit = 1024
    static let wrappers: Set<String> = ["sudo", "doas", "env", "time", "exec", "nohup", "command", "builtin", "nice"]
    static let promptEnds = ["$ ", "# ", "% ", "❯ ", "> ", "» "]

    var directory: String? { reading.directory }
    var job: String? { reading.job }

    /// The marks carried over to a reader that starts again from what the server still holds:
    /// the reading stays until the replay says otherwise, and nothing half-read survives.
    func restarted() -> ShellMarks {
        var fresh = ShellMarks()
        fresh.reading = reading
        fresh.marked = marked
        fresh.alternate = alternate
        return fresh
    }

    mutating func read(_ bytes: Data) {
        for byte in bytes { step(byte) }
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            ground(byte)
        case .escape:
            switch byte {
            case 0x5D:
                payload.removeAll(keepingCapacity: true)
                state = .osc
            case 0x5B:
                payload.removeAll(keepingCapacity: true)
                state = .csi
            default:
                state = .ground
            }
        case .osc:
            switch byte {
            case 0x07:
                finishOSC()
            case 0x1B:
                state = .oscEscape
            default:
                if payload.count < Self.payloadLimit { payload.append(byte) }
            }
        case .oscEscape:
            if byte == 0x5C {
                finishOSC()
            } else {
                state = .escape
                step(byte)
            }
        case .csi:
            if (0x40...0x7E).contains(byte) {
                finishCSI(final: byte)
            } else if payload.count < 64 {
                payload.append(byte)
            }
        }
    }

    private mutating func ground(_ byte: UInt8) {
        switch byte {
        case 0x1B:
            state = .escape
        case 0x0D, 0x0A:
            commitLine()
        case 0x08:
            if !line.isEmpty { line.removeLast() }
        case 0x20..<0x7F, 0x80...:
            if line.count < Self.lineLimit { line.append(byte) }
        default:
            break
        }
    }

    private mutating func commitLine() {
        defer {
            line.removeAll(keepingCapacity: true)
            commandStart = nil
        }
        guard !line.isEmpty else { return }
        if let commandStart, commandStart <= line.count {
            lastLine = Array(line[commandStart...])
            lastLineIsCommand = true
        } else {
            lastLine = line
            lastLineIsCommand = false
        }
    }

    private mutating func finishCSI(final: UInt8) {
        defer { state = .ground }
        guard final == 0x68 || final == 0x6C, payload.first == 0x3F else { return }
        let modes = String(decoding: payload.dropFirst(), as: UTF8.self).split(separator: ";")
        guard modes.contains(where: { $0 == "1049" || $0 == "1047" || $0 == "47" }) else { return }
        let entering = final == 0x68
        guard entering != alternate else { return }
        alternate = entering
        guard !marked else { return }
        reading.job = entering ? (program() ?? "program") : nil
    }

    private mutating func finishOSC() {
        defer { state = .ground }
        let text = String(decoding: payload, as: UTF8.self)
        guard let separator = text.firstIndex(of: ";") else { return }
        let code = text[..<separator]
        let body = String(text[text.index(after: separator)...])
        switch code {
        case "7":
            if let path = URLComponents(string: body)?.path, !path.isEmpty { reading.directory = path }
        case "1337":
            if body.hasPrefix("CurrentDir=") { reading.directory = String(body.dropFirst("CurrentDir=".count)) }
        case "133":
            marked = true
            switch body.prefix(1) {
            case "A", "D": reading.job = nil
            case "B": commandStart = line.count
            case "C": reading.job = program() ?? "program"
            default: break
            }
        case "3008":
            context(body)
        default:
            break
        }
    }

    /// One of systemd's context marks: `start=ID;type=shell|command;…;cwd=…` or `end=ID;…`.
    private mutating func context(_ body: String) {
        var fields: [String: String] = [:]
        for field in body.split(separator: ";") {
            guard let equals = field.firstIndex(of: "=") else { continue }
            fields[String(field[..<equals])] = Self.unescaped(String(field[field.index(after: equals)...]))
        }
        if let cwd = fields["cwd"], cwd.hasPrefix("/") { reading.directory = cwd }
        if let id = fields["start"] {
            switch fields["type"] {
            case "shell":
                marked = true
                reading.job = nil
            case "command":
                marked = true
                commands.insert(id)
                reading.job = program() ?? "program"
            default:
                break
            }
        } else if let id = fields["end"], commands.remove(id) != nil {
            reading.job = nil
        }
    }

    /// systemd writes a `;`, a `\` or a byte that is not printable as `\xNN`.
    private static func unescaped(_ value: String) -> String {
        guard value.contains("\\x") else { return value }
        var bytes: [UInt8] = []
        let utf8 = Array(value.utf8)
        var index = 0
        while index < utf8.count {
            if utf8[index] == 0x5C, index + 3 < utf8.count, utf8[index + 1] == 0x78,
                let byte = UInt8(String(decoding: utf8[(index + 2)...(index + 3)], as: UTF8.self), radix: 16)
            {
                bytes.append(byte)
                index += 4
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The program the last echoed line started, read past the prompt and past the words that
    /// only run another program (`sudo`, `env`, `VAR=value`).
    private func program() -> String? {
        let source = line.isEmpty ? lastLine : line
        var text = String(decoding: source, as: UTF8.self)
        if !(line.isEmpty ? lastLineIsCommand : commandStart != nil) {
            let ends = Self.promptEnds.compactMap { text.range(of: $0, options: .backwards) }
            if let last = ends.max(by: { $0.upperBound < $1.upperBound }) {
                text = String(text[last.upperBound...])
            }
        }
        if !line.isEmpty, let commandStart, commandStart <= line.count {
            text = String(decoding: line[commandStart...], as: UTF8.self)
        }
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if word.contains("=") || word.hasPrefix("-") || Self.wrappers.contains(String(word)) { continue }
            let name = (String(word) as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            return String(name.prefix(40))
        }
        return nil
    }
}
