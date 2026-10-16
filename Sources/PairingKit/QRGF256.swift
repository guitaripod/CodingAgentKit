enum QRGF256 {
    static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var product = 0
        for bit in stride(from: 7, through: 0, by: -1) {
            product = (product << 1) ^ ((product >> 7) * 0x11D)
            product ^= ((Int(y) >> bit) & 1) * Int(x)
        }
        return UInt8(product)
    }

    /// The monic generator polynomial of the given degree without its leading coefficient.
    static func generator(degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree)
        result[degree - 1] = 1
        var root: UInt8 = 1
        for _ in 0..<degree {
            for index in 0..<degree {
                result[index] = multiply(result[index], root)
                if index + 1 < degree { result[index] ^= result[index + 1] }
            }
            root = multiply(root, 2)
        }
        return result
    }

    static func remainder(of data: [UInt8], generator: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: generator.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for (index, coefficient) in generator.enumerated() {
                result[index] ^= multiply(coefficient, factor)
            }
        }
        return result
    }
}
