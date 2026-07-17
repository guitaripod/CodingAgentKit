/// Incremental server-sent-events parser: feed raw bytes, get dispatched events.
/// Implements the WHATWG field rules (data/event/id, comment lines), treats
/// LF, CRLF, and bare CR as line terminators, and strips a leading UTF-8 BOM.
struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastEventID: String?
    private var isFirstLine = true
    private var skipNextLF = false

    mutating func consume(_ byte: UInt8) -> SSEvent? {
        if skipNextLF {
            skipNextLF = false
            if byte == 0x0A { return nil }
        }
        switch byte {
        case 0x0D:
            skipNextLF = true
            return processLine()
        case 0x0A:
            return processLine()
        default:
            line.append(byte)
            return nil
        }
    }

    private mutating func processLine() -> SSEvent? {
        stripByteOrderMarkIfFirstLine()
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty {
            guard !dataLines.isEmpty else {
                eventType = nil
                return nil
            }
            let event = SSEvent(
                id: lastEventID, type: eventType, data: dataLines.joined(separator: "\n"))
            dataLines.removeAll()
            eventType = nil
            return event
        }
        guard line.first != UInt8(ascii: ":") else { return nil }
        let string = String(decoding: line, as: UTF8.self)
        let field: String
        var value: String
        if let colon = string.firstIndex(of: ":") {
            field = String(string[..<colon])
            value = String(string[string.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = string
            value = ""
        }
        switch field {
        case "data": dataLines.append(value)
        case "event": eventType = value
        case "id": if !value.contains("\0") { lastEventID = value }
        default: break
        }
        return nil
    }

    /// The WHATWG spec requires ignoring one U+FEFF at the very start of the
    /// stream; left in place, its UTF-8 bytes would corrupt the first line's
    /// field name and silently drop that field.
    private mutating func stripByteOrderMarkIfFirstLine() {
        guard isFirstLine else { return }
        isFirstLine = false
        if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
    }
}
