struct QRMatrix {
    let size: Int
    let version: Int
    private(set) var modules: [Bool]
    private var isFunction: [Bool]

    init(version: Int) {
        self.version = version
        size = QRTables.size(of: version)
        modules = [Bool](repeating: false, count: size * size)
        isFunction = modules
        drawFunctionPatterns()
    }

    subscript(x: Int, y: Int) -> Bool { modules[y * size + x] }

    private mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y * size + x] = dark
        isFunction[y * size + x] = true
    }

    private mutating func drawFunctionPatterns() {
        for index in 0..<size {
            setFunction(6, index, index % 2 == 0)
            setFunction(index, 6, index % 2 == 0)
        }
        drawFinder(at: 3, 3)
        drawFinder(at: size - 4, 3)
        drawFinder(at: 3, size - 4)
        let positions = QRTables.alignmentPositions(version: version)
        let last = positions.count - 1
        for (row, y) in positions.enumerated() {
            for (column, x) in positions.enumerated() {
                let overlapsFinder = (row == 0 && column == 0) || (row == 0 && column == last) || (row == last && column == 0)
                if !overlapsFinder { drawAlignment(at: x, y) }
            }
        }
        drawFormat(mask: 0)
        drawVersion()
    }

    private mutating func drawFinder(at centerX: Int, _ centerY: Int) {
        for dy in -4...4 {
            for dx in -4...4 {
                let x = centerX + dx
                let y = centerY + dy
                guard x >= 0, x < size, y >= 0, y < size else { continue }
                let distance = max(abs(dx), abs(dy))
                setFunction(x, y, distance != 2 && distance != 4)
            }
        }
    }

    private mutating func drawAlignment(at centerX: Int, _ centerY: Int) {
        for dy in -2...2 {
            for dx in -2...2 {
                setFunction(centerX + dx, centerY + dy, max(abs(dx), abs(dy)) != 1)
            }
        }
    }

    mutating func drawFormat(mask: Int, level: QRLevel = .low) {
        let bits = QRFormat.formatBits(level: level, mask: mask)
        func bit(_ index: Int) -> Bool { (bits >> index) & 1 == 1 }
        for index in 0...5 { setFunction(8, index, bit(index)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for index in 9..<15 { setFunction(14 - index, 8, bit(index)) }
        for index in 0..<8 { setFunction(size - 1 - index, 8, bit(index)) }
        for index in 8..<15 { setFunction(8, size - 15 + index, bit(index)) }
        setFunction(8, size - 8, true)
    }

    private mutating func drawVersion() {
        guard version >= 7 else { return }
        let bits = QRFormat.versionBits(version: version)
        for index in 0..<18 {
            let dark = (bits >> index) & 1 == 1
            let a = size - 11 + index % 3
            let b = index / 3
            setFunction(a, b, dark)
            setFunction(b, a, dark)
        }
    }

    mutating func placeCodewords(_ codewords: [UInt8]) {
        var bitIndex = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for offset in 0..<2 {
                    let x = right - offset
                    let upward = ((right + 1) & 2) == 0
                    let y = upward ? size - 1 - vertical : vertical
                    if !isFunction[y * size + x], bitIndex < codewords.count * 8 {
                        modules[y * size + x] = (codewords[bitIndex >> 3] >> UInt8(7 - (bitIndex & 7))) & 1 == 1
                        bitIndex += 1
                    }
                }
            }
            right -= 2
        }
    }

    mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y * size + x] && QRMatrix.inverts(mask: mask, x: x, y: y) {
                modules[y * size + x].toggle()
            }
        }
    }

    private static func inverts(mask: Int, x: Int, y: Int) -> Bool {
        switch mask {
        case 0: (x + y) % 2 == 0
        case 1: y % 2 == 0
        case 2: x % 3 == 0
        case 3: (x + y) % 3 == 0
        case 4: (x / 3 + y / 2) % 2 == 0
        case 5: x * y % 2 + x * y % 3 == 0
        case 6: (x * y % 2 + x * y % 3) % 2 == 0
        default: ((x + y) % 2 + x * y % 3) % 2 == 0
        }
    }
}
