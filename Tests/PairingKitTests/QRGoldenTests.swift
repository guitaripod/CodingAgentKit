import Testing

@testable import PairingKit

@Suite struct QRGoldenTests {
    private static let helloWorldMedium = [
        "111111101100101111111", "100000100001001000001", "101110100101001011101", "101110101001001011101",
        "101110101110101011101", "100000101001001000001", "111111101010101111111", "000000001001100000000",
        "100010111111011111001", "000100001011100001111", "001111110011011010010", "111110001100010000000",
        "111110101010101100110", "000000001010111101011", "111111101110101011010", "100000100101110110011",
        "101110101101011000110", "101110100100100011011", "101110100111000111000", "100000100001010000000",
        "111111101111111110101",
    ]

    @Test func helloWorldAtMediumMatchesTheMatrixAnIndependentDecoderRead() throws {
        let code = try QRCode.encode("HELLO WORLD", level: .medium)
        let rows = code.modules.map { row in String(row.map { $0 ? Character("1") : Character("0") }) }
        #expect(code.version == 1)
        #expect(rows == Self.helloWorldMedium)
    }
}
