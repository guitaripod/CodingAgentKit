public enum QRLevel: Int, Sendable, Hashable, CaseIterable {
    case low, medium, quartile, high

    public static let l = QRLevel.low
    public static let m = QRLevel.medium
    public static let q = QRLevel.quartile
    public static let h = QRLevel.high

    var formatBits: Int {
        switch self {
        case .low: 1
        case .medium: 0
        case .quartile: 3
        case .high: 2
        }
    }
}
