import Foundation

/// One record on the frame stream. A frame carries its capture time so a client can pace playback
/// without trusting its own clock.
public enum FrameRecord: Sendable, Equatable {
    case frame(microseconds: UInt64, jpeg: Data)
    case event(Data)
    case heartbeat
}

public enum FrameCodecError: Error, Equatable {
    case payloadTooLarge(Int)
    case malformedFrame
}

/// Length-prefixed records, so a reader can skip a kind it does not know and a newer host can add
/// kinds without breaking an older client.
public enum FrameCodec {
    static let headerLength = 5
    static let timestampLength = 8

    /// The payload length is a 32-bit field, so a single record above 4 GiB is outside the protocol.
    public static func encode(_ record: FrameRecord) -> Data {
        switch record {
        case let .frame(microseconds, jpeg):
            return packet(.frame, payload: bigEndian(microseconds) + jpeg)
        case let .event(json):
            return packet(.event, payload: json)
        case .heartbeat:
            return packet(.heartbeat, payload: Data())
        }
    }

    private static func packet(_ kind: FrameKind, payload: Data) -> Data {
        Data([kind.rawValue]) + bigEndian(UInt32(payload.count)) + payload
    }

    private static func bigEndian<Value: FixedWidthInteger>(_ value: Value) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

enum FrameKind: UInt8, Sendable {
    case frame = 0x01
    case event = 0x02
    case heartbeat = 0x03
}

/// Decodes the frame stream incrementally. A throw is terminal: the framing cannot be trusted after
/// a length it refused, so the caller should drop the connection rather than feed more bytes.
public struct FrameDecoder: Sendable {
    private let maximumPayloadBytes: Int
    private var pending: [UInt8] = []

    /// The limit is checked as soon as a header arrives, so a hostile length cannot make the decoder
    /// wait for, or allocate, a payload it was never going to accept.
    public init(maximumPayloadBytes: Int = 64_000_000) {
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public mutating func feed(_ chunk: Data) throws -> [FrameRecord] {
        pending.append(contentsOf: chunk)
        var records: [FrameRecord] = []
        var offset = 0
        while pending.count - offset >= FrameCodec.headerLength {
            let length = pending[(offset + 1)..<(offset + FrameCodec.headerLength)].reduce(0) {
                ($0 << 8) | Int($1)
            }
            guard length <= maximumPayloadBytes else {
                throw FrameCodecError.payloadTooLarge(length)
            }
            let payloadStart = offset + FrameCodec.headerLength
            guard pending.count - payloadStart >= length else { break }
            let payload = pending[payloadStart..<(payloadStart + length)]
            if let record = try Self.record(kind: pending[offset], payload: payload) {
                records.append(record)
            }
            offset = payloadStart + length
        }
        pending.removeFirst(offset)
        return records
    }

    private static func record(kind: UInt8, payload: ArraySlice<UInt8>) throws -> FrameRecord? {
        switch FrameKind(rawValue: kind) {
        case .frame:
            guard payload.count >= FrameCodec.timestampLength else { throw FrameCodecError.malformedFrame }
            let microseconds = payload.prefix(FrameCodec.timestampLength).reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            return .frame(microseconds: microseconds, jpeg: Data(payload.dropFirst(FrameCodec.timestampLength)))
        case .event:
            return .event(Data(payload))
        case .heartbeat:
            return .heartbeat
        case nil:
            return nil
        }
    }
}
