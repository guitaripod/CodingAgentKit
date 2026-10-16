import Foundation

/// Draws a `QRCode` as text. `ansi` sets its own colours and scans on any terminal theme. `blocks` and
/// `ascii` use the terminal's own colours: a dark module is a filled cell, which scans with dark text
/// on a light background, and `inverse` fills the light modules instead for light text on dark.
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

    /// Two module rows per line drawn with `▀`: foreground is the upper module, background the lower,
    /// from the 256-colour palette (black 16, white 231), so the symbol is dark on light whatever the
    /// terminal theme. Every line ends with a reset so nothing bleeds into the prompt.
    public static func ansi(_ code: QRCode) -> String {
        let low = -quietZone
        let high = code.size + quietZone
        var lines: [String] = []
        for top in stride(from: low, to: high, by: 2) {
            var line = ""
            var current: (Int, Int)?
            for x in low..<high {
                let colors = (paletteColor(code[x, top]), paletteColor(code[x, top + 1]))
                if current == nil || current! != colors {
                    line += "\u{1B}[38;5;\(colors.0);48;5;\(colors.1)m"
                    current = colors
                }
                line += "▀"
            }
            lines.append(line + reset)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The best rendering for where it is going: `ansi` on a colour-capable Unicode terminal, then
    /// `blocks` on any Unicode locale, then `ascii`.
    public static func render(
        _ code: QRCode, inverse: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTerminal: Bool = isatty(STDOUT_FILENO) != 0
    ) -> String {
        guard supportsUnicode(environment: environment) else { return ascii(code, inverse: inverse) }
        if isTerminal, supportsColor(environment: environment) { return ansi(code) }
        return blocks(code, inverse: inverse)
    }

    /// Whether the terminal advertises 256 colours (or more) and the person has not asked for none.
    public static func supportsColor(environment: [String: String]) -> Bool {
        if let noColor = environment["NO_COLOR"], !noColor.isEmpty { return false }
        let term = environment["TERM"] ?? ""
        if term.isEmpty || term == "dumb" || term == "linux" { return false }
        return term.contains("256color") || !(environment["COLORTERM"] ?? "").isEmpty
    }

    /// Whether the locale says UTF-8 and the terminal is not a bare Linux console or a dumb one.
    public static func supportsUnicode(environment: [String: String]) -> Bool {
        if let term = environment["TERM"], term == "linux" || term == "dumb" { return false }
        let locale = ["LC_ALL", "LC_CTYPE", "LANG"].compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        let normalized = locale.lowercased().replacingOccurrences(of: "-", with: "")
        return normalized.contains("utf8")
    }

    private static let reset = "\u{1B}[0m"
    private static let blackColor = 16
    private static let whiteColor = 231

    private static func paletteColor(_ dark: Bool) -> Int { dark ? blackColor : whiteColor }

    private static func filled(_ code: QRCode, _ x: Int, _ y: Int, inverse: Bool) -> Bool {
        code[x, y] != inverse
    }
}
