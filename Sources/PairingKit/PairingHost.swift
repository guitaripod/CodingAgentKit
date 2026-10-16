/// Syntax checks for the host field of a pairing link and the address families it can name.
enum PairingHost {
    static let maxLength = 253
    private static let maxLabelLength = 63

    /// The host as stored: lowercased, IPv6 literals without brackets. `nil` when the syntax is wrong.
    static func normalized(_ raw: String) -> String? {
        let host = raw.lowercased()
        guard !host.isEmpty, host.utf8.count <= maxLength, host.unicodeScalars.allSatisfy(isAllowed) else {
            return nil
        }
        if host.contains(":") || host.contains("[") || host.contains("]") {
            let bare = unbracketed(host)
            return bare.flatMap(ipv6) == nil ? nil : bare
        }
        return isDomainOrIPv4(host) ? host : nil
    }

    static func ipv4(_ host: String) -> [UInt8]? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4 else { return nil }
        var octets: [UInt8] = []
        for label in labels {
            guard !label.isEmpty, label.count <= 3, label.allSatisfy(\.isASCIIDigit),
                let value = UInt8(label)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    static func ipv6(_ host: String) -> [UInt16]? {
        let sides = host.components(separatedBy: "::")
        guard sides.count <= 2, !host.contains(":::") else { return nil }
        guard let head = groups(sides[0]), let tail = sides.count == 2 ? groups(sides[1]) : [] else {
            return nil
        }
        if sides.count == 2 {
            guard head.count + tail.count <= 7 else { return nil }
            return head + [UInt16](repeating: 0, count: 8 - head.count - tail.count) + tail
        }
        return head.count == 8 ? head : nil
    }

    private static func groups(_ text: String) -> [UInt16]? {
        if text.isEmpty { return [] }
        var result: [UInt16] = []
        for group in text.split(separator: ":", omittingEmptySubsequences: false) {
            guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit),
                let value = UInt16(group, radix: 16)
            else { return nil }
            result.append(value)
        }
        return result
    }

    private static func unbracketed(_ host: String) -> String? {
        let opens = host.hasPrefix("[")
        let closes = host.hasSuffix("]")
        if opens != closes { return nil }
        let bare = opens ? String(host.dropFirst().dropLast()) : host
        return bare.contains("[") || bare.contains("]") ? nil : bare
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x61...0x7A, 0x2D, 0x2E, 0x3A, 0x5B, 0x5D: true
        default: false
        }
    }

    private static func isDomainOrIPv4(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let wellFormed = labels.allSatisfy { label in
            (1...maxLabelLength).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
        }
        guard wellFormed else { return false }
        let numeric = labels.allSatisfy { $0.allSatisfy(\.isASCIIDigit) }
        return !numeric || ipv4(host) != nil
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
