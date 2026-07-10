import Testing

@testable import AgentCore

struct SSEParserTests {
    private func parse(_ input: String) -> [SSEvent] {
        var parser = SSEParser()
        var events: [SSEvent] = []
        for byte in input.utf8 {
            if let event = parser.consume(byte) { events.append(event) }
        }
        return events
    }

    @Test func parsesSimpleEvent() {
        let events = parse("event: message\ndata: hello\n\n")
        #expect(events == [SSEvent(id: nil, type: "message", data: "hello")])
    }

    @Test func joinsMultilineDataAndTracksID() {
        let events = parse("id: 7\ndata: a\ndata: b\n\n")
        #expect(events == [SSEvent(id: "7", type: nil, data: "a\nb")])
    }

    @Test func handlesCRLFAndComments() {
        let events = parse(": keepalive\r\ndata: x\r\n\r\ndata: y\r\n\r\n")
        #expect(events.map(\.data) == ["x", "y"])
        #expect(events[1].id == nil)
    }

    @Test func blankLineWithoutDataDispatchesNothing() {
        #expect(parse("event: ping\n\n").isEmpty)
    }

    @Test func stripsSingleLeadingSpaceOnly() {
        let events = parse("data:  padded\n\n")
        #expect(events.first?.data == " padded")
    }

    @Test func retainsLastEventIDAcrossEvents() {
        let events = parse("id: 1\ndata: a\n\ndata: b\n\n")
        #expect(events.map(\.id) == ["1", "1"])
    }
}
