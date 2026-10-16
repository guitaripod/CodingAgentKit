import Testing

@testable import PairingKit

@Suite struct TerminalQRAnsiTests {
    private static let escape = Character("\u{1B}")
    private static let reset = "\u{1B}[0m"

    static func parse(_ text: String) -> [[(top: Int, bottom: Int)]] {
        text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map { line in
            var cells: [(top: Int, bottom: Int)] = []
            var foreground = -1
            var background = -1
            var index = line.startIndex
            while index < line.endIndex {
                if line[index] == escape {
                    let end = line[index...].firstIndex(of: "m")!
                    let parameters = line[line.index(index, offsetBy: 2)..<end].split(separator: ";").map(String.init)
                    if parameters == ["0"] {
                        foreground = -1
                        background = -1
                    } else {
                        #expect(parameters.count == 6 && parameters[0] == "38" && parameters[1] == "5" && parameters[3] == "48" && parameters[4] == "5")
                        foreground = Int(parameters[2])!
                        background = Int(parameters[5])!
                    }
                    index = line.index(after: end)
                } else {
                    #expect(line[index] == "▀")
                    cells.append((foreground, background))
                    index = line.index(after: index)
                }
            }
            return cells
        }
    }

    private func code() throws -> QRCode { try QRCode.encode(QRPayloads.link) }

    @Test func everyLineStartsWithColorsAndEndsWithAReset() throws {
        let text = TerminalQR.ansi(try code())
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        for line in lines {
            #expect(line.hasPrefix("\u{1B}[38;5;"))
            #expect(line.hasSuffix(Self.reset))
            #expect(!line.dropLast(Self.reset.count).contains("\u{1B}[0m"))
        }
    }

    @Test func usesOnlyBlackAndWhiteFromThe256Palette() throws {
        for row in Self.parse(TerminalQR.ansi(try code())) {
            for cell in row {
                #expect([16, 231].contains(cell.top) && [16, 231].contains(cell.bottom))
            }
        }
    }

    @Test func widthAndHeightFollowTheSymbolAndQuietZone() throws {
        let code = try code()
        let rows = Self.parse(TerminalQR.ansi(code))
        #expect(rows.count == (code.size + 4 + 1) / 2)
        #expect(rows.allSatisfy { $0.count == code.size + 4 })
    }

    @Test func theQuietZoneIsWhite() throws {
        let code = try code()
        let rows = Self.parse(TerminalQR.ansi(code))
        #expect(rows[0].allSatisfy { $0.top == 231 && $0.bottom == 231 })
        #expect(rows.last!.allSatisfy { $0.bottom == 231 })
        for row in rows {
            #expect(row[0] == (231, 231) && row[1] == (231, 231))
            #expect(row[row.count - 1] == (231, 231) && row[row.count - 2] == (231, 231))
        }
    }

    @Test func theModuleMatrixIsRecoverableFromTheEscapes() throws {
        for level in QRLevel.allCases {
            let code = try QRCode.encode(QRPayloads.link, level: level)
            let rows = Self.parse(TerminalQR.ansi(code))
            var recovered = [[Bool]](repeating: [Bool](repeating: false, count: code.size), count: code.size)
            for (line, row) in rows.enumerated() {
                for (column, cell) in row.enumerated() {
                    let x = column - TerminalQR.quietZone
                    for (offset, color) in [(0, cell.top), (1, cell.bottom)] {
                        let y = line * 2 - TerminalQR.quietZone + offset
                        if (0..<code.size).contains(x), (0..<code.size).contains(y) { recovered[y][x] = color == 16 }
                    }
                }
            }
            #expect(recovered == code.modules)
        }
    }

    @Test func adjacentCellsOfOneColorShareASingleSequence() throws {
        let text = TerminalQR.ansi(try code())
        let first = text.split(separator: "\n")[0]
        #expect(first.filter { $0 == Self.escape }.count == 2)
    }
}
