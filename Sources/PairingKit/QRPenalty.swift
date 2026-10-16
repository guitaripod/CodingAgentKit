enum QRPenalty {
    private static let runPenalty = 3
    private static let blockPenalty = 3
    private static let finderPenalty = 40
    private static let balancePenalty = 10

    static func score(_ matrix: QRMatrix) -> Int {
        let size = matrix.size
        var result = 0
        for line in 0..<size {
            result += runsScore(size: size) { matrix[$0, line] }
            result += runsScore(size: size) { matrix[line, $0] }
        }
        result += blocksScore(matrix)
        result += balanceScore(matrix)
        return result
    }

    private static func runsScore(size: Int, module: (Int) -> Bool) -> Int {
        var result = 0
        var runColor = false
        var runLength = 0
        var history = [Int](repeating: 0, count: 7)
        for index in 0..<size {
            if module(index) == runColor {
                runLength += 1
                if runLength == 5 {
                    result += runPenalty
                } else if runLength > 5 {
                    result += 1
                }
            } else {
                addHistory(runLength, to: &history, size: size)
                if !runColor { result += patternCount(history) * finderPenalty }
                runColor = module(index)
                runLength = 1
            }
        }
        result += terminateAndCount(color: runColor, length: runLength, history: &history, size: size) * finderPenalty
        return result
    }

    private static func blocksScore(_ matrix: QRMatrix) -> Int {
        var result = 0
        for y in 0..<matrix.size - 1 {
            for x in 0..<matrix.size - 1 {
                let color = matrix[x, y]
                if color == matrix[x + 1, y], color == matrix[x, y + 1], color == matrix[x + 1, y + 1] {
                    result += blockPenalty
                }
            }
        }
        return result
    }

    private static func balanceScore(_ matrix: QRMatrix) -> Int {
        let total = matrix.size * matrix.size
        let dark = (0..<total).filter { matrix[$0 % matrix.size, $0 / matrix.size] }.count
        let steps = (abs(dark * 20 - total * 10) + total - 1) / total - 1
        return steps * balancePenalty
    }

    private static func patternCount(_ history: [Int]) -> Int {
        let unit = history[1]
        let core = unit > 0 && history[2] == unit && history[3] == unit * 3 && history[4] == unit && history[5] == unit
        let leading = core && history[0] >= unit * 4 && history[6] >= unit
        let trailing = core && history[6] >= unit * 4 && history[0] >= unit
        return (leading ? 1 : 0) + (trailing ? 1 : 0)
    }

    private static func terminateAndCount(color: Bool, length: Int, history: inout [Int], size: Int) -> Int {
        var length = length
        if color {
            addHistory(length, to: &history, size: size)
            length = 0
        }
        length += size
        addHistory(length, to: &history, size: size)
        return patternCount(history)
    }

    private static func addHistory(_ length: Int, to history: inout [Int], size: Int) {
        var length = length
        if history[0] == 0 { length += size }
        history.removeLast()
        history.insert(length, at: 0)
    }
}
