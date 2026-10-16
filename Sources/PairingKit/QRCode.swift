import Foundation

/// A QR Code symbol, versions 1 through 12, in byte mode.
public struct QRCode: Sendable, Hashable {
    public let size: Int
    public let version: Int
    public let level: QRLevel
    public let mask: Int
    private let cells: [Bool]

    /// Encodes the UTF-8 bytes of `text` at the smallest version that holds them at `level`.
    public static func encode(_ text: String, level: QRLevel = .medium) throws -> QRCode {
        try encode(bytes: Array(text.utf8), level: level)
    }

    public static func encode(bytes: [UInt8], level: QRLevel = .medium) throws -> QRCode {
        guard let version = smallestVersion(byteCount: bytes.count, level: level) else {
            throw QRError.tooLong
        }
        let data = QRCodewords.data(for: bytes, version: version, level: level)
        let codewords = QRCodewords.interleaved(data, version: version, level: level)
        var matrix = QRMatrix(version: version)
        matrix.placeCodewords(codewords)
        let mask = bestMask(for: &matrix, level: level)
        matrix.applyMask(mask)
        matrix.drawFormat(mask: mask, level: level)
        return QRCode(size: matrix.size, version: version, level: level, mask: mask, cells: matrix.modules)
    }

    /// How many bytes fit at the largest supported version for `level`.
    public static func capacity(level: QRLevel) -> Int {
        capacity(version: QRTables.maxVersion, level: level)
    }

    public static func capacity(version: Int, level: QRLevel) -> Int {
        let dataBits = QRTables.dataCodewords(version: version, level: level) * 8
        return max(0, (dataBits - 4 - QRTables.characterCountBits(version: version)) / 8)
    }

    /// Whether the module at column `x`, row `y` is dark; anything outside the symbol is light.
    public subscript(x: Int, y: Int) -> Bool {
        guard x >= 0, x < size, y >= 0, y < size else { return false }
        return cells[y * size + x]
    }

    /// Rows from the top, each from the left.
    public var modules: [[Bool]] {
        (0..<size).map { y in Array(cells[y * size..<(y + 1) * size]) }
    }

    private static func smallestVersion(byteCount: Int, level: QRLevel) -> Int? {
        (QRTables.minVersion...QRTables.maxVersion).first { version in
            QRCodewords.bitCount(byteCount: byteCount, version: version)
                <= QRTables.dataCodewords(version: version, level: level) * 8
        }
    }

    private static func bestMask(for matrix: inout QRMatrix, level: QRLevel) -> Int {
        var best = 0
        var bestScore = Int.max
        for mask in 0..<8 {
            matrix.applyMask(mask)
            matrix.drawFormat(mask: mask, level: level)
            let score = QRPenalty.score(matrix)
            if score < bestScore {
                best = mask
                bestScore = score
            }
            matrix.applyMask(mask)
        }
        return best
    }
}
