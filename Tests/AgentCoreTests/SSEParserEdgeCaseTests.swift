import Testing

@testable import AgentCore

@Suite struct SSEParserEdgeCaseTests {
    private let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Feeds every byte individually through `consume`, which is precisely the
    /// byte-at-a-time contract that splits any multi-byte UTF-8 sequence across
    /// separate `consume` calls.
    private func parse(_ bytes: [UInt8]) -> [SSEvent] {
        var parser = SSEParser()
        var events: [SSEvent] = []
        for byte in bytes {
            if let event = parser.consume(byte) { events.append(event) }
        }
        return events
    }

    private func parse(_ input: String) -> [SSEvent] {
        parse(Array(input.utf8))
    }

    @Test func multilineDataJoinsWithNewlinesIncludingBlankDataLine() {
        let events = parse("data: a\ndata:\ndata: c\n\n")
        #expect(events == [SSEvent(id: nil, type: nil, data: "a\n\nc")])
    }

    @Test func crlfTerminatedEventParsesAllFields() {
        let events = parse("id: 3\r\nevent: msg\r\ndata: x\r\n\r\n")
        #expect(events == [SSEvent(id: "3", type: "msg", data: "x")])
    }

    @Test func carriageReturnOnlyTerminatorsDispatchAllFields() {
        let events = parse("id: 9\revent: note\rdata: hi\r\r")
        #expect(events == [SSEvent(id: "9", type: "note", data: "hi")])
    }

    @Test func carriageReturnOnlyMultilineDataJoinsWithNewlines() {
        let events = parse("data: a\rdata: b\r\r")
        #expect(events.map(\.data) == ["a\nb"])
    }

    @Test func mixedLineTerminatorsEachDispatchAnEvent() {
        let events = parse("data: a\n\ndata: b\r\n\r\ndata: c\r\r")
        #expect(events.map(\.data) == ["a", "b", "c"])
    }

    @Test func leadingBOMStrippedFirstFieldNameIntact() {
        let bytes = bom + Array("event: greet\ndata: hi\n\n".utf8)
        #expect(parse(bytes) == [SSEvent(id: nil, type: "greet", data: "hi")])
    }

    @Test func bomStrippedExactlyOnceNotOnLaterLines() {
        let bytes = bom + Array("data: a\n".utf8) + bom + Array("data: b\n\n".utf8)
        let events = parse(bytes)
        #expect(events.count == 1)
        #expect(events.first?.data == "a")
    }

    @Test func eventAndIdFieldsAreSetIndependently() {
        let events = parse("event: update\nid: 42\ndata: payload\n\n")
        #expect(events == [SSEvent(id: "42", type: "update", data: "payload")])
    }

    @Test func leadingColonLineIsCommentAndIgnored() {
        let events = parse(": this is a comment\ndata: real\n\n")
        #expect(events.count == 1)
        #expect(events.first == SSEvent(id: nil, type: nil, data: "real"))
    }

    @Test func fieldWithNoColonYieldsEmptyStringValue() {
        let events = parse("data\n\n")
        #expect(events == [SSEvent(id: nil, type: nil, data: "")])
    }

    @Test func colonWithEmptyValueYieldsEmptyData() {
        let events = parse("data:\n\n")
        #expect(events == [SSEvent(id: nil, type: nil, data: "")])
    }

    @Test func singleLeadingSpaceAfterColonStrippedOnce() {
        #expect(parse("data: x\n\n").first?.data == "x")
        #expect(parse("data:x\n\n").first?.data == "x")
        #expect(parse("data:  x\n\n").first?.data == " x")
    }

    @Test func multiByteUTF8FourByteEmojiFedByteByByteDecodes() {
        let bytes = Array("data: ".utf8) + [0xF0, 0x9F, 0x8E, 0x89] + Array("\n\n".utf8)
        #expect(parse(bytes).first?.data == "🎉")
    }

    @Test func multiByteUTF8AcrossMultipleDataLinesDecodes() {
        let events = parse("data: café\ndata: 日本\n\n")
        #expect(events == [SSEvent(id: nil, type: nil, data: "café\n日本")])
    }
}
