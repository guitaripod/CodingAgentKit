import Foundation

/// Draws a `QRCode` as text. By default a dark module is a filled cell, which scans on a terminal
/// with dark text on a light background; `inverse` fills the light modules instead for a terminal
/// with light text on a dark background.
public enum TerminalQR {
    public static let quietZone = 2

    /// Two module rows per text line using the half blocks.
    public static func blocks(_ code: QRCode, inverse: Bool = false) -> String {
        let low = -quietZone
        let high = code.size + quietZone
        var lines: [String] = []
        for top in stride(from: low, to: high, by: 2) {
            var line = ""
            for x in low..<high {
                let upper = filled(code, x, top, inverse: inverse)
                let lower = filled(code, x, top + 1, inverse: inverse)
                line.append(upper ? (lower ? "█" : "▀") : (lower ? "▄" : " "))
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Two characters per module, `##` and two spaces, for terminals without Unicode.
    public static func ascii(_ code: QRCode, inverse: Bool = false) -> String {
        let range = -quietZone..<code.size + quietZone
        return range.map { y in
            range.map { x in filled(code, x, y, inverse: inverse) ? "##" : "  " }.joined()
        }.joined(separator: "\n") + "\n"
    }

    public static func render(
        _ code: QRCode, inverse: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        supportsUnicode(environment: environment)
            ? blocks(code, inverse: inverse) : ascii(code, inverse: inverse)
    }

    /// Whether the locale says UTF-8 and the terminal is not a bare Linux console or a dumb one.
    public static func supportsUnicode(environment: [String: String]) -> Bool {
        if let term = environment["TERM"], term == "linux" || term == "dumb" { return false }
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let normalized = locale.lowercased().replacingOccurrences(of: "-", with: "")
        return normalized.contains("utf8")
    }

    private static func filled(_ code: QRCode, _ x: Int, _ y: Int, inverse: Bool) -> Bool {
        code[x, y] != inverse
    }
}
