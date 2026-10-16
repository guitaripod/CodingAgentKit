import Testing

@testable import PairingKit

@Suite struct QREncoderTests {
    private func bits(_ value: Int, width: Int) -> String {
        let text = String(value, radix: 2)
        return String(repeating: "0", count: width - text.count) + text
    }

    @Test func formatInformationMatchesThePublishedTable() {
        #expect(bits(QRFormat.formatBits(level: .medium, mask: 0), width: 15) == "101010000010010")
        #expect(bits(QRFormat.formatBits(level: .low, mask: 0), width: 15) == "111011111000100")
        #expect(bits(QRFormat.formatBits(level: .quartile, mask: 0), width: 15) == "011010101011111")
        #expect(bits(QRFormat.formatBits(level: .high, mask: 0), width: 15) == "001011010001001")
        #expect(bits(QRFormat.formatBits(level: .low, mask: 4), width: 15) == "110011000101111")
        #expect(bits(QRFormat.formatBits(level: .low, mask: 7), width: 15) == "110100101110110")
        #expect(bits(QRFormat.formatBits(level: .high, mask: 7), width: 15) == "000100000111011")
    }

    @Test func everyFormatWordIsAValidBCHCodeword() {
        var seen = Set<Int>()
        for level in QRLevel.allCases {
            for mask in 0..<8 {
                let word = QRFormat.formatBits(level: level, mask: mask) ^ 0x5412
                var remainder = word
                for shift in stride(from: 14, through: 10, by: -1) where (remainder >> shift) & 1 == 1 {
                    remainder ^= 0x537 << (shift - 10)
                }
                #expect(remainder == 0)
                seen.insert(word)
            }
        }
        #expect(seen.count == 32)
    }

    @Test func versionInformationMatchesThePublishedTable() {
        #expect(QRFormat.versionBits(version: 7) == 0x07C94)
        #expect(QRFormat.versionBits(version: 8) == 0x085BC)
        #expect(QRFormat.versionBits(version: 9) == 0x09A99)
        #expect(QRFormat.versionBits(version: 10) == 0x0A4D3)
        #expect(QRFormat.versionBits(version: 11) == 0x0BBF6)
        #expect(QRFormat.versionBits(version: 12) == 0x0C762)
    }

    @Test func generatorPolynomialsMatchTheStandard() {
        #expect(QRGF256.generator(degree: 7) == [127, 122, 154, 164, 11, 68, 117])
        #expect(QRGF256.generator(degree: 10) == [216, 194, 159, 111, 199, 94, 95, 113, 157, 193])
    }

    @Test func generatorExponentsMatchTheStandard() {
        var logs = [UInt8: Int]()
        var value: UInt8 = 1
        for exponent in 0..<255 {
            logs[value] = exponent
            value = QRGF256.multiply(value, 2)
        }
        #expect(logs.count == 255)
        #expect([0] + QRGF256.generator(degree: 7).map { logs[$0]! } == [0, 87, 229, 146, 149, 238, 102, 21])
        #expect(
            [0] + QRGF256.generator(degree: 10).map { logs[$0]! } == [0, 251, 67, 46, 61, 118, 70, 64, 94, 32, 45])
    }

    @Test func reedSolomonMatchesThePublishedHelloWorldExample() {
        let data: [UInt8] = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236, 17, 236, 17]
        let ecc = QRGF256.remainder(of: data, generator: QRGF256.generator(degree: 10))
        #expect(ecc == [196, 35, 39, 119, 235, 215, 231, 226, 93, 23])
    }

    @Test func capacitiesMatchTheStandard() {
        let expected: [(Int, QRLevel, Int)] = [
            (1, .low, 17), (1, .medium, 14), (1, .quartile, 11), (1, .high, 7),
            (2, .low, 32), (2, .medium, 26), (3, .low, 53), (4, .low, 78), (5, .medium, 84), (7, .low, 154),
            (9, .high, 98), (10, .low, 271), (10, .medium, 213), (10, .quartile, 151), (10, .high, 119),
        ]
        for (version, level, bytes) in expected {
            #expect(QRCode.capacity(version: version, level: level) == bytes, "v\(version) \(level)")
        }
        #expect(QRCode.capacity(level: .low) > 0)
    }

    @Test func rawModuleCountsMatchTheStandard() {
        #expect(QRTables.rawDataModules(version: 1) == 208)
        #expect(QRTables.rawDataModules(version: 2) == 359)
        #expect(QRTables.rawDataModules(version: 7) == 1568)
        #expect(QRTables.rawDataModules(version: 10) == 2768)
    }

    @Test func picksTheSmallestVersionAndRejectsWhatDoesNotFit() throws {
        #expect(try QRCode.encode(String(repeating: "a", count: 17), level: .low).version == 1)
        #expect(try QRCode.encode(String(repeating: "a", count: 18), level: .low).version == 2)
        #expect(try QRCode.encode(String(repeating: "a", count: 7), level: .high).version == 1)
        #expect(try QRCode.encode(String(repeating: "a", count: 8), level: .high).version == 2)
        for level in QRLevel.allCases {
            let capacity = QRCode.capacity(level: level)
            #expect(try QRCode.encode(String(repeating: "a", count: capacity), level: level).version == 12)
            #expect(throws: QRError.tooLong) {
                try QRCode.encode(String(repeating: "a", count: capacity + 1), level: level)
            }
        }
    }

    @Test func sizesFollowTheVersion() throws {
        for count in [1, 20, 50, 100, 200, 300] {
            let code = try QRCode.encode(String(repeating: "x", count: count), level: .low)
            #expect(code.size == code.version * 4 + 17)
            #expect(code.modules.count == code.size)
            #expect(code.modules.allSatisfy { $0.count == code.size })
        }
    }

    @Test func functionPatternsAreInPlace() throws {
        for text in ["A", String(repeating: "b", count: 120), String(repeating: "c", count: 300)] {
            let code = try QRCode.encode(text, level: .low)
            let last = code.size - 1
            for (originX, originY) in [(0, 0), (last - 6, 0), (0, last - 6)] {
                for dy in 0..<7 {
                    for dx in 0..<7 {
                        let ring = max(abs(dx - 3), abs(dy - 3))
                        #expect(code[originX + dx, originY + dy] == (ring != 2), "finder")
                    }
                }
            }
            for index in 8...(last - 8) {
                #expect(code[index, 6] == (index % 2 == 0))
                #expect(code[6, index] == (index % 2 == 0))
            }
            #expect(code[8, last - 7])
        }
    }

    @Test func bothFormatCopiesAgreeAndNameTheLevelAndMask() throws {
        for level in QRLevel.allCases {
            let code = try QRCode.encode("hello", level: level)
            let last = code.size - 1
            var first = 0
            let firstCopy = [(8, 0), (8, 1), (8, 2), (8, 3), (8, 4), (8, 5), (8, 7), (8, 8), (7, 8), (5, 8), (4, 8), (3, 8), (2, 8), (1, 8), (0, 8)]
            for (index, point) in firstCopy.enumerated() where code[point.0, point.1] { first |= 1 << index }
            var second = 0
            let secondCopy = (0..<8).map { (last - $0, 8) } + (8..<15).map { (8, last - 14 + $0) }
            for (index, point) in secondCopy.enumerated() where code[point.0, point.1] { second |= 1 << index }
            #expect(first == second)
            #expect(first == QRFormat.formatBits(level: level, mask: code.mask))
        }
    }

    @Test func versionInformationIsDrawnTwiceFromVersionSeven() throws {
        let code = try QRCode.encode(String(repeating: "z", count: 200), level: .low)
        #expect(code.version >= 7)
        let bits = QRFormat.versionBits(version: code.version)
        for index in 0..<18 {
            let dark = (bits >> index) & 1 == 1
            #expect(code[code.size - 11 + index % 3, index / 3] == dark)
            #expect(code[index / 3, code.size - 11 + index % 3] == dark)
        }
    }

    @Test func encodingIsDeterministicAndLevelsDiffer() throws {
        let a = try QRCode.encode(QRPayloads.link)
        #expect(try QRCode.encode(QRPayloads.link) == a)
        #expect(try QRCode.encode(QRPayloads.link, level: .high) != a)
        #expect(try QRCode.encode(bytes: Array(QRPayloads.link.utf8)) == a)
    }

    @Test func outsideTheSymbolIsLight() throws {
        let code = try QRCode.encode("A")
        #expect(!code[-1, 0] && !code[0, -1] && !code[code.size, 0] && !code[0, code.size])
    }

    @Test func everyPayloadAtEveryLevelEncodesOrReportsTooLong() throws {
        for payload in QRPayloads.all() {
            for level in QRLevel.allCases {
                if payload.text.utf8.count <= QRCode.capacity(level: level) {
                    let code = try QRCode.encode(payload.text, level: level)
                    #expect(code.size >= 21 && code.size <= 77)
                } else {
                    #expect(throws: QRError.tooLong) { try QRCode.encode(payload.text, level: level) }
                }
            }
        }
    }
}
