import Foundation
import Testing

@testable import PreviewKit

private let sampleRecords: [FrameRecord] = [
    .frame(microseconds: 1_234_567, jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9])),
    .event(Data("{\"kind\":\"built\"}".utf8)),
    .heartbeat,
]

@Suite struct FrameCodecTests {
    @Test func heartbeatHasTheDocumentedLayout() {
        #expect(FrameCodec.encode(.heartbeat) == Data([0x03, 0, 0, 0, 0]))
    }

    @Test func everyKindRoundTrips() throws {
        for record in sampleRecords {
            var decoder = FrameDecoder()
            #expect(try decoder.feed(FrameCodec.encode(record)) == [record])
        }
    }

    @Test func oneByteChunksDecodeTheSameRecords() throws {
        var stream = Data()
        for record in sampleRecords {
            stream.append(FrameCodec.encode(record))
        }
        var decoder = FrameDecoder()
        var decoded: [FrameRecord] = []
        for byte in stream {
            decoded += try decoder.feed(Data([byte]))
        }
        #expect(decoded == sampleRecords)
    }

    @Test func unknownKindIsSkippedByItsLength() throws {
        var decoder = FrameDecoder()
        let unknown = Data([0x7F, 0, 0, 0, 3, 1, 2, 3])
        #expect(try decoder.feed(unknown + FrameCodec.encode(.heartbeat)) == [.heartbeat])
    }

    @Test func declaredLengthAboveTheMaximumThrows() {
        var decoder = FrameDecoder(maximumPayloadBytes: 10)
        #expect(throws: FrameCodecError.payloadTooLarge(100)) {
            try decoder.feed(Data([0x02, 0, 0, 0, 100]))
        }
    }

    @Test func frameShorterThanATimestampThrows() {
        var decoder = FrameDecoder()
        #expect(throws: FrameCodecError.malformedFrame) {
            try decoder.feed(Data([0x01, 0, 0, 0, 3, 1, 2, 3]))
        }
    }
}
