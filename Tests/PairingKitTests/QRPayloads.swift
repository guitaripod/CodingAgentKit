import Foundation

@testable import PairingKit

enum QRPayloads {
    static let link = "tailscode://connect?v=1&host=mac.tail1234.ts.net&port=8787&agent=claude&name=Marcus%20Desktop"

    static func all() -> [(name: String, text: String)] {
        let keyed = PairingLink(host: "100.101.102.103", port: 4096, agent: .omp, name: "Studio", key: "s3cret-pass")!
        let long = PairingLink(
            host: "workstation.tail1234.ts.net", port: 8787, agent: .opencode,
            name: String(repeating: "Long Machine ", count: 5), key: "k3y")!
        let emoji = PairingLink(host: "mac.ts.net", port: 8787, agent: .claude, name: "Café 😀 日本", key: nil)!
        return [
            ("link", link),
            ("link-key", keyed.url.absoluteString),
            ("link-long-name", long.url.absoluteString),
            ("link-emoji-name", emoji.url.absoluteString),
            ("ten", "0123456789"),
            ("single", "A"),
            ("hello-world", "HELLO WORLD"),
            ("empty", ""),
            ("utf8", "Grüße, 世界 😀"),
            ("chars-150", filler(150)),
            ("chars-300", filler(300)),
            ("chars-400", filler(400)),
        ]
    }

    private static func filler(_ count: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:/?&=%-._~")
        var generator = SplitMix(state: UInt64(count))
        return String((0..<count).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
