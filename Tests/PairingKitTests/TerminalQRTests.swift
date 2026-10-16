import Testing

@testable import PairingKit

@Suite struct TerminalQRTests {
    private func code() throws -> QRCode { try QRCode.encode("tailscode") }

    @Test func blocksUseTwoRowsPerLineAndAQuietZone() throws {
        let code = try code()
        let lines = TerminalQR.blocks(code).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == (code.size + 4 + 1) / 2)
        #expect(lines.allSatisfy { $0.count == code.size + 4 })
        #expect(lines.first.map(String.init) == String(repeating: " ", count: code.size + 4))
    }

    @Test func blocksEncodeEachModulePair() throws {
        let code = try code()
        let text = TerminalQR.blocks(code)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(Array.init)
        for (row, line) in lines.enumerated() {
            for (column, glyph) in line.enumerated() {
                let upper = code[column - 2, row * 2 - 2]
                let lower = code[column - 2, row * 2 - 1]
                let expected: Character = upper ? (lower ? "█" : "▀") : (lower ? "▄" : " ")
                #expect(glyph == expected)
            }
        }
    }

    @Test func inverseSwapsDarkAndLight() throws {
        let code = try code()
        let normal = TerminalQR.blocks(code).split(separator: "\n").map(Array.init)
        let inverse = TerminalQR.blocks(code, inverse: true).split(separator: "\n").map(Array.init)
        #expect(inverse.first == Array(repeating: "█", count: code.size + 4))
        let swap: [Character: Character] = ["█": " ", " ": "█", "▀": "▄", "▄": "▀"]
        for row in 1..<normal.count - 1 {
            #expect(inverse[row] == normal[row].map { swap[$0]! })
        }
    }

    @Test func asciiIsTwoCharactersPerModule() throws {
        let code = try code()
        let lines = TerminalQR.ascii(code).split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == code.size + 4)
        #expect(lines.allSatisfy { $0.count == (code.size + 4) * 2 })
        #expect(lines.first.map(String.init) == String(repeating: " ", count: (code.size + 4) * 2))
        let row = Array(lines[2])
        for x in 0..<code.size {
            #expect(String(row[(x + 2) * 2..<(x + 2) * 2 + 2]) == (code[x, 0] ? "##" : "  "))
        }
        #expect(TerminalQR.ascii(code, inverse: true).hasPrefix(String(repeating: "#", count: (code.size + 4) * 2)))
    }

    @Test func unicodeSupportFollowsTheLocaleAndTerminal() {
        #expect(TerminalQR.supportsUnicode(environment: ["LANG": "en_US.UTF-8", "TERM": "xterm-256color"]))
        #expect(TerminalQR.supportsUnicode(environment: ["LC_ALL": "C.utf8"]))
        #expect(!TerminalQR.supportsUnicode(environment: ["LANG": "C"]))
        #expect(!TerminalQR.supportsUnicode(environment: [:]))
        #expect(!TerminalQR.supportsUnicode(environment: ["LANG": "en_US.UTF-8", "TERM": "linux"]))
        #expect(!TerminalQR.supportsUnicode(environment: ["LANG": "en_US.UTF-8", "LC_ALL": "C"]))
        #expect(!TerminalQR.supportsUnicode(environment: ["LANG": "en_US.UTF-8", "TERM": "dumb"]))
    }

    @Test func renderPicksTheFallback() throws {
        let code = try code()
        #expect(TerminalQR.render(code, environment: ["LANG": "en_US.UTF-8"]) == TerminalQR.blocks(code))
        #expect(TerminalQR.render(code, environment: ["LANG": "C"]) == TerminalQR.ascii(code))
    }
}
