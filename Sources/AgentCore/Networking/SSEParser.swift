/// Incremental server-sent-events parser: feed raw bytes, get dispatched events.
/// Implements the WHATWG field rules (data/event/id, comment lines, CRLF tolerance).
struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var dataLines: [String] = []
    private var eventType: String?
    private var lastEventID: String?

    mutating func consume(_ byte: UInt8) -> SSEvent? {
        if byte == 0x0A { return processLine() }
        line.append(byte)
        return nil
    }

    private mutating func processLine() -> SSEvent? {
        if line.last == 0x0D { line.removeLast() }
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
}
