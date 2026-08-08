import Foundation

/// What one path in the working tree is doing, as git reports it.
///
/// The two status letters stay apart: `index` is what a commit would take, `worktree` is what it
/// would leave behind, and a file that is both is the case a reader most needs told rather than
/// flattened into one word.
public struct GitChange: Sendable, Hashable, Codable, Identifiable {
    public var path: String
    /// Where a renamed or copied file came from.
    public var original: String?
    public var index: String?
    public var worktree: String?
    public var untracked: Bool
    /// An untracked whole directory: git reports it as one entry instead of descending into it.
    public var directory: Bool
    public var conflicted: Bool
    public var submodule: Bool
    public var binary: Bool
    public var insertions: Int
    public var deletions: Int
    public var stagedInsertions: Int
    public var stagedDeletions: Int
    public var bytes: Int?
    public var contains: Int?
    /// The file count stopped early — the directory holds at least that many.
    public var containsAtLeast: Bool

    public var id: String { path }

    public init(
        path: String, original: String? = nil, index: String? = nil, worktree: String? = nil,
        untracked: Bool = false, directory: Bool = false, conflicted: Bool = false,
        submodule: Bool = false, binary: Bool = false, insertions: Int = 0, deletions: Int = 0,
        stagedInsertions: Int = 0, stagedDeletions: Int = 0, bytes: Int? = nil,
        contains: Int? = nil, containsAtLeast: Bool = false
    ) {
        self.path = path
        self.original = original
        self.index = index
        self.worktree = worktree
        self.untracked = untracked
        self.directory = directory
        self.conflicted = conflicted
        self.submodule = submodule
        self.binary = binary
        self.insertions = insertions
        self.deletions = deletions
        self.stagedInsertions = stagedInsertions
        self.stagedDeletions = stagedDeletions
        self.bytes = bytes
        self.contains = contains
        self.containsAtLeast = containsAtLeast
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        original = try container.decodeIfPresent(String.self, forKey: .original)
        index = try container.decodeIfPresent(String.self, forKey: .index)
        worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
        untracked = try container.decodeIfPresent(Bool.self, forKey: .untracked) ?? false
        directory = try container.decodeIfPresent(Bool.self, forKey: .directory) ?? false
        conflicted = try container.decodeIfPresent(Bool.self, forKey: .conflicted) ?? false
        submodule = try container.decodeIfPresent(Bool.self, forKey: .submodule) ?? false
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        insertions = try container.decodeIfPresent(Int.self, forKey: .insertions) ?? 0
        deletions = try container.decodeIfPresent(Int.self, forKey: .deletions) ?? 0
        stagedInsertions = try container.decodeIfPresent(Int.self, forKey: .stagedInsertions) ?? 0
        stagedDeletions = try container.decodeIfPresent(Int.self, forKey: .stagedDeletions) ?? 0
        bytes = try container.decodeIfPresent(Int.self, forKey: .bytes)
        contains = try container.decodeIfPresent(Int.self, forKey: .contains)
        containsAtLeast =
            try container.decodeIfPresent(Bool.self, forKey: .containsAtLeast) ?? false
    }

    /// Changes anywhere: staged plus unstaged, which is what a row states next to a path.
    public var totalInsertions: Int { insertions + stagedInsertions }
    public var totalDeletions: Int { deletions + stagedDeletions }
    public var isStaged: Bool { index != nil && !untracked && !conflicted }
    public var isUnstaged: Bool { worktree != nil && !untracked && !conflicted }
}

public struct GitCommitSummary: Sendable, Hashable, Codable, Identifiable {
    public var hash: String
    public var short: String
    public var subject: String
    public var author: String
    public var at: Date
    /// Branch and tag names pointing at this commit, as git decorates them.
    public var refs: [String]

    public var id: String { hash }

    public init(
        hash: String, short: String, subject: String, author: String, at: Date,
        refs: [String] = []
    ) {
        self.hash = hash
        self.short = short
        self.subject = subject
        self.author = author
        self.at = at
        self.refs = refs
    }
}

/// The repository behind a conversation, read whole. Every figure here is a fact the server
/// measured; nothing in this type implies an operation the client could perform.
public struct GitSnapshot: Sendable, Hashable, Codable {
    public var root: String
    public var repo: Bool
    public var branch: String?
    public var detached: Bool
    public var head: String?
    public var upstream: String?
    public var ahead: Int
    public var behind: Int
    public var stashes: Int
    /// A merge, rebase, cherry-pick, revert or bisect in progress.
    public var operation: String?
    public var remote: String?
    public var fetchedAt: Date?
    public var changes: [GitChange]
    public var commits: [GitCommitSummary]
    public var truncated: Bool
    public var changedTotal: Int

    public init(
        root: String, repo: Bool = true, branch: String? = nil, detached: Bool = false,
        head: String? = nil, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
        stashes: Int = 0, operation: String? = nil, remote: String? = nil, fetchedAt: Date? = nil,
        changes: [GitChange] = [], commits: [GitCommitSummary] = [], truncated: Bool = false,
        changedTotal: Int = 0
    ) {
        self.root = root
        self.repo = repo
        self.branch = branch
        self.detached = detached
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.stashes = stashes
        self.operation = operation
        self.remote = remote
        self.fetchedAt = fetchedAt
        self.changes = changes
        self.commits = commits
        self.truncated = truncated
        self.changedTotal = changedTotal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decodeIfPresent(String.self, forKey: .root) ?? ""
        repo = try container.decodeIfPresent(Bool.self, forKey: .repo) ?? true
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        detached = try container.decodeIfPresent(Bool.self, forKey: .detached) ?? false
        head = try container.decodeIfPresent(String.self, forKey: .head)
        upstream = try container.decodeIfPresent(String.self, forKey: .upstream)
        ahead = try container.decodeIfPresent(Int.self, forKey: .ahead) ?? 0
        behind = try container.decodeIfPresent(Int.self, forKey: .behind) ?? 0
        stashes = try container.decodeIfPresent(Int.self, forKey: .stashes) ?? 0
        operation = try container.decodeIfPresent(String.self, forKey: .operation)
        remote = try container.decodeIfPresent(String.self, forKey: .remote)
        fetchedAt = try container.decodeIfPresent(Date.self, forKey: .fetchedAt)
        changes = try container.decodeIfPresent([GitChange].self, forKey: .changes) ?? []
        commits = try container.decodeIfPresent([GitCommitSummary].self, forKey: .commits) ?? []
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        changedTotal = try container.decodeIfPresent(Int.self, forKey: .changedTotal) ?? 0
    }
}

public struct GitPatch: Sendable, Hashable, Codable {
    public var path: String
    public var staged: Bool
    public var patch: String
    public var binary: Bool
    public var truncated: Bool

    public init(
        path: String, staged: Bool, patch: String, binary: Bool = false, truncated: Bool = false
    ) {
        self.path = path
        self.staged = staged
        self.patch = patch
        self.binary = binary
        self.truncated = truncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        staged = try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false
        patch = try container.decodeIfPresent(String.self, forKey: .patch) ?? ""
        binary = try container.decodeIfPresent(Bool.self, forKey: .binary) ?? false
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

public struct GitCommitDetail: Sendable, Hashable, Codable {
    public var hash: String
    public var short: String
    public var subject: String
    public var body: String?
    public var author: String
    public var email: String?
    public var at: Date
    public var refs: [String]
    public var parents: [String]
    public var files: [GitChange]
    public var patch: String?
    public var truncated: Bool

    public init(
        hash: String, short: String, subject: String, body: String? = nil, author: String,
        email: String? = nil, at: Date, refs: [String] = [], parents: [String] = [],
        files: [GitChange] = [], patch: String? = nil, truncated: Bool = false
    ) {
        self.hash = hash
        self.short = short
        self.subject = subject
        self.body = body
        self.author = author
        self.email = email
        self.at = at
        self.refs = refs
        self.parents = parents
        self.files = files
        self.patch = patch
        self.truncated = truncated
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        short = try container.decodeIfPresent(String.self, forKey: .short) ?? String(hash.prefix(8))
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email)
        at = try container.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        refs = try container.decodeIfPresent([String].self, forKey: .refs) ?? []
        parents = try container.decodeIfPresent([String].self, forKey: .parents) ?? []
        files = try container.decodeIfPresent([GitChange].self, forKey: .files) ?? []
        patch = try container.decodeIfPresent(String.self, forKey: .patch)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// A backend that can describe the repository its agent is working in — and only describe it.
/// Reading is the whole contract: nothing here stages, commits, pulls or pushes, because a change
/// made from a phone is a change nobody reviewed on the machine that will have to live with it.
///
/// Every method returns nil for a server that has no answer — an older bridge without the routes,
/// or a backend that never had them — so a client can tell "no repository here" apart from "this
/// server cannot say", and show neither as an error.
public protocol GitObservingBackend: CodingAgentBackend {
    func gitSnapshot(directory: String?, sessionID: String?) async throws -> GitSnapshot?
    func gitPatch(directory: String?, sessionID: String?, path: String, staged: Bool) async throws
        -> GitPatch?
    func gitCommit(directory: String?, sessionID: String?, hash: String) async throws
        -> GitCommitDetail?
}
