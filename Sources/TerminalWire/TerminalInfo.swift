import Foundation

/// A shell a server is holding, as the server describes it.
///
/// The shell runs on the machine the agent works on, in a pseudo-terminal the server owns, so it
/// outlives the client that opened it: an app that is closed, a phone that sleeps or a connection
/// that drops finds the same shell, the same folder and whatever was running when it comes back.
/// Every field is the server's own reading, taken when asked.
public struct TerminalInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// The shell's name as a person knows it (`bash`), never its path.
    public var shell: String
    /// The folder the shell is standing in now, read from the process itself so every `cd`,
    /// `pushd` and jump counts. Absent when the machine could not read it.
    public var directory: String?
    /// The program in front of the shell (`vim`, `cargo`), absent while the shell waits at its
    /// prompt. A terminal with one is doing something a restart would destroy.
    public var job: String?
    public var cols: Int
    public var rows: Int
    public var startedAt: Date
    /// The conversation the terminal was opened beside, when it was opened beside one.
    public var session: String?
    /// The name the client that opened it gave, so the same client finds its terminal again
    /// after it has been closed and opened: a desk's own shell on this machine.
    public var desk: String?
    /// How the shell ended, absent while it runs.
    public var exitCode: Int?
    /// How many clients are reading its output at this moment.
    public var attached: Int
    /// The number of bytes the shell has written since it started: where a reader that has
    /// everything so far would ask to continue from.
    public var offset: UInt64

    public init(
        id: String, shell: String, directory: String? = nil, job: String? = nil, cols: Int,
        rows: Int, startedAt: Date, session: String? = nil, desk: String? = nil,
        exitCode: Int? = nil, attached: Int = 0, offset: UInt64 = 0
    ) {
        self.id = id
        self.shell = shell
        self.directory = directory
        self.job = job
        self.cols = cols
        self.rows = rows
        self.startedAt = startedAt
        self.session = session
        self.desk = desk
        self.exitCode = exitCode
        self.attached = attached
        self.offset = offset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        shell = try container.decodeIfPresent(String.self, forKey: .shell) ?? "sh"
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        job = try container.decodeIfPresent(String.self, forKey: .job)
        cols = try container.decodeIfPresent(Int.self, forKey: .cols) ?? 80
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 24
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        session = try container.decodeIfPresent(String.self, forKey: .session)
        desk = try container.decodeIfPresent(String.self, forKey: .desk)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        attached = try container.decodeIfPresent(Int.self, forKey: .attached) ?? 0
        offset = try container.decodeIfPresent(UInt64.self, forKey: .offset) ?? 0
    }

    /// Whether the shell is still there to type into.
    public var isRunning: Bool { exitCode == nil }

    /// Whether something is running in front of the shell.
    public var isBusy: Bool { isRunning && job != nil }
}

/// What a client asks for when it opens a terminal.
public struct TerminalOpenRequest: Codable, Sendable, Equatable {
    /// The folder to start in. A folder that is not there starts the shell at home instead.
    public var directory: String?
    /// The conversation it is opened beside: where the shell starts when no folder is named.
    public var session: String?
    /// The name this client will look for when it comes back (``TerminalInfo/desk``).
    public var desk: String?
    public var cols: Int
    public var rows: Int

    public init(
        directory: String? = nil, session: String? = nil, desk: String? = nil, cols: Int = 80,
        rows: Int = 24
    ) {
        self.directory = directory
        self.session = session
        self.desk = desk
        self.cols = cols
        self.rows = rows
    }
}

public struct TerminalResizeRequest: Codable, Sendable, Equatable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

/// The sizes a terminal may be asked to take. A window dragged to nothing, or a client with a bug,
/// must not hand the kernel a size no program can draw in.
public enum TerminalSize {
    public static let columns = 2...1000
    public static let rows = 1...500

    public static func clamped(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        (
            min(max(cols, columns.lowerBound), columns.upperBound),
            min(max(rows, self.rows.lowerBound), self.rows.upperBound)
        )
    }
}
