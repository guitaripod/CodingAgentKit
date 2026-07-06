public struct FileNode: Identifiable, Sendable, Hashable {
    public var path: String
    public var name: String
    public var isDirectory: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
    }
}

public struct FileDiff: Identifiable, Sendable, Hashable {
    public var path: String
    public var additions: Int
    public var deletions: Int
    public var patch: String?

    public var id: String { path }

    public init(path: String, additions: Int, deletions: Int, patch: String? = nil) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}
