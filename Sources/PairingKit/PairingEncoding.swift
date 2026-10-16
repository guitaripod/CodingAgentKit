enum PairingEncoding {
    private static let hex = Array("0123456789ABCDEF".utf8)

    static func encode(_ value: String) -> String {
        var out: [UInt8] = []
        for byte in value.utf8 {
            if isUnreserved(byte) {
                out.append(byte)
            } else {
                out.append(0x25)
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Strict: a stray `%`, a bad escape or bytes that are not UTF-8 give `nil`.
    static func decode(_ value: Substring) -> String? {
        var out: [UInt8] = []
        var iterator = value.utf8.makeIterator()
        while let byte = iterator.next() {
            guard byte == 0x25 else {
                out.append(byte)
                continue
            }
            guard let high = iterator.next().flatMap(hexValue), let low = iterator.next().flatMap(hexValue) else {
                return nil
            }
            out.append(high << 4 | low)
        }
        return String(validating: out, as: UTF8.self)
    }

    /// Control characters, line and paragraph separators and bidirectional overrides, none of which
    /// belong in a machine name shown on a setup screen.
    static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E: true
        default: false
        }
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}
