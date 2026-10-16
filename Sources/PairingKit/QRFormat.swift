enum QRFormat {
    /// The 15 format bits (level and mask, BCH protected, XOR-masked) as the standard prints them.
    static func formatBits(level: QRLevel, mask: Int) -> Int {
        let data = level.formatBits << 3 | mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        return (data << 10 | remainder) ^ 0x5412
    }

    /// The 18 version bits (version and its Golay remainder) for versions 7 and up.
    static func versionBits(version: Int) -> Int {
        var remainder = version
        for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
        return version << 12 | remainder
    }
}
