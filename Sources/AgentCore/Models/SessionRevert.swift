import Foundation

/// A conversation wound back to a point, with the way back still open.
///
/// Reverting sets aside every message from ``messageID`` on and puts the files the agent changed
/// after that point back as they were, but only provisionally: the messages stay on the server
/// and the change can be undone, until the next prompt makes it final. A client shows the
/// conversation as it stands before the boundary and says what was set aside, because a revert
/// nobody can see is a conversation that silently lost its end.
public struct SessionRevert: Sendable, Hashable, Codable {
    /// One file the revert put back.
    public struct File: Sendable, Hashable, Codable {
        public enum Change: String, Sendable, Hashable, Codable {
            case added
            case modified
            case deleted
        }

        public var path: String
        /// What the revert did to the file: a file the agent added is deleted, one it deleted is
        /// added back, one it edited is put back as it was.
        public var change: Change
        public var additions: Int
        public var deletions: Int
        /// The revert's own diff for the file, where the server gave one.
        public var patch: String?

        public init(
            path: String, change: Change, additions: Int = 0, deletions: Int = 0,
            patch: String? = nil
        ) {
            self.path = path
            self.change = change
            self.additions = additions
            self.deletions = deletions
            self.patch = patch
        }
    }

    /// The first message set aside; it and everything after it are no longer in effect.
    public var messageID: String
    public var files: [File]

    public init(messageID: String, files: [File] = []) {
        self.messageID = messageID
        self.files = files
    }
}
