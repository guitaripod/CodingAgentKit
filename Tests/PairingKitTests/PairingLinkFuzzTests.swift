import Foundation
import Testing

@testable import PairingKit

struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct PairingLinkFuzzTests {
    private static let fragments = [
        "tailscode://", "connect", "?", "&", "=", "#", "%", "%2", "%41", "%FF", "%00", "v", "host", "port", "agent",
        "name", "key", "claude", "omp", "opencode", "100.64.0.1", "[::1]", "fd7a:115c:a1e0::1", "a.b", "65535", "0",
        "-1", "99999999999999999999", "@", ":", "/", " ", "\n", "é", "😀", "\u{0}", "\u{202E}", "..", "[", "]",
    ]

    private static let seed = "tailscode://connect?v=1&host=mac.tail1234.ts.net&port=8787&agent=claude&name=Desk%20%F0%9F%98%80&key=pw"

    private func random(_ generator: inout SplitMix) -> String {
        let count = Int.random(in: 0...14, using: &generator)
        return (0..<count).map { _ in Self.fragments.randomElement(using: &generator)! }.joined()
    }

    private func mutated(_ generator: inout SplitMix) -> String {
        var scalars = Array(Self.seed.unicodeScalars)
        for _ in 0..<Int.random(in: 1...4, using: &generator) {
            let kind = Int.random(in: 0...2, using: &generator)
            let at = Int.random(in: 0..<max(scalars.count, 1), using: &generator)
            let replacement = Self.fragments.randomElement(using: &generator)!.unicodeScalars
            switch kind {
            case 0 where !scalars.isEmpty: scalars.remove(at: at)
            case 1: scalars.insert(contentsOf: replacement, at: min(at, scalars.count))
            default:
                if !scalars.isEmpty { scalars.replaceSubrange(at...at, with: replacement) }
            }
        }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars)
        return String(text)
    }

    @Test func twoThousandHostileStringsNeverCrashAndAcceptedOnesAreCanonical() {
        var generator = SplitMix(state: 0xC0DE_CAFE)
        var accepted = 0
        for index in 0..<2000 {
            let text = index % 2 == 0 ? random(&generator) : mutated(&generator)
            guard let link = PairingLink(string: text) else { continue }
            accepted += 1
            #expect(PairingLink(url: link.url) == link, "\(text)")
            #expect((1...65535).contains(link.port))
            #expect((link.name?.count ?? 0) <= 64)
            #expect((link.key?.count ?? 0) <= 200)
        }
        #expect(accepted > 0)
    }

    @Test func randomBytesNeverCrash() {
        var generator = SplitMix(state: 42)
        for _ in 0..<500 {
            let length = Int.random(in: 0...300, using: &generator)
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = PairingLink(string: String(decoding: bytes, as: UTF8.self))
        }
    }

    @Test func hugeInputIsRejectedQuickly() {
        let huge = "tailscode://connect?v=1&host=a.b&port=1&agent=omp&name=" + String(repeating: "A", count: 2_000_000)
        #expect(PairingLink(string: huge) == nil)
    }
}
