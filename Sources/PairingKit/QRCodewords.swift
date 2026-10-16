enum QRCodewords {
    /// The data codewords for a byte-mode segment, padded to the version's capacity.
    static func data(for bytes: [UInt8], version: Int, level: QRLevel) -> [UInt8] {
        var bits: [Bool] = []
        append(0b0100, count: 4, to: &bits)
        append(bytes.count, count: QRTables.characterCountBits(version: version), to: &bits)
        for byte in bytes { append(Int(byte), count: 8, to: &bits) }
        let capacityBits = QRTables.dataCodewords(version: version, level: level) * 8
        append(0, count: min(4, capacityBits - bits.count), to: &bits)
        append(0, count: (8 - bits.count % 8) % 8, to: &bits)
        var padByte = 0xEC
        while bits.count < capacityBits {
            append(padByte, count: 8, to: &bits)
            padByte ^= 0xEC ^ 0x11
        }
        return stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | ($1 ? 1 : 0) }
        }
    }

    static func bitCount(byteCount: Int, version: Int) -> Int {
        4 + QRTables.characterCountBits(version: version) + byteCount * 8
    }

    /// Splits the data into blocks, appends each block's error correction and interleaves them.
    static func interleaved(_ data: [UInt8], version: Int, level: QRLevel) -> [UInt8] {
        let blockCount = QRTables.blocks(version: version, level: level)
        let eccLength = QRTables.eccCodewords(version: version, level: level)
        let rawCodewords = QRTables.rawDataModules(version: version) / 8
        let shortBlocks = blockCount - rawCodewords % blockCount
        let shortLength = rawCodewords / blockCount
        let generator = QRGF256.generator(degree: eccLength)

        var blocks: [[UInt8]] = []
        var offset = 0
        for index in 0..<blockCount {
            let length = shortLength - eccLength + (index < shortBlocks ? 0 : 1)
            var block = Array(data[offset..<offset + length])
            offset += length
            let ecc = QRGF256.remainder(of: block, generator: generator)
            if index < shortBlocks { block.append(0) }
            blocks.append(block + ecc)
        }

        var result: [UInt8] = []
        for column in 0..<blocks[0].count {
            for (index, block) in blocks.enumerated()
            where column != shortLength - eccLength || index >= shortBlocks {
                result.append(block[column])
            }
        }
        return result
    }

    private static func append(_ value: Int, count: Int, to bits: inout [Bool]) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            bits.append((value >> shift) & 1 == 1)
        }
    }
}
