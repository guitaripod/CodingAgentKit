enum QRTables {
    static let minVersion = 1
    static let maxVersion = 12

    private static let eccCodewordsPerBlock: [[Int]] = [
        [7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24],
        [10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22],
        [13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26],
        [17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28],
    ]

    private static let blockCounts: [[Int]] = [
        [1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4],
        [1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8],
        [1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10],
        [1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11],
    ]

    static func size(of version: Int) -> Int { version * 4 + 17 }

    static func eccCodewords(version: Int, level: QRLevel) -> Int {
        eccCodewordsPerBlock[level.rawValue][version - 1]
    }

    static func blocks(version: Int, level: QRLevel) -> Int {
        blockCounts[level.rawValue][version - 1]
    }

    /// Modules left for codewords once every function pattern is excluded.
    static func rawDataModules(version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let alignments = version / 7 + 2
            result -= (25 * alignments - 10) * alignments - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    static func dataCodewords(version: Int, level: QRLevel) -> Int {
        rawDataModules(version: version) / 8
            - eccCodewords(version: version, level: level) * blocks(version: version, level: level)
    }

    static func characterCountBits(version: Int) -> Int { version <= 9 ? 8 : 16 }

    static func alignmentPositions(version: Int) -> [Int] {
        if version == 1 { return [] }
        let count = version / 7 + 2
        let step = (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
        var positions = [6]
        var position = size(of: version) - 7
        for _ in 0..<(count - 1) {
            positions.insert(position, at: 1)
            position -= step
        }
        return positions
    }
}
