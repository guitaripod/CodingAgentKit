public struct SSEvent: Sendable, Hashable {
    public let id: String?
    public let type: String?
    public let data: String

    public init(id: String?, type: String?, data: String) {
        self.id = id
        self.type = type
        self.data = data
    }
}
