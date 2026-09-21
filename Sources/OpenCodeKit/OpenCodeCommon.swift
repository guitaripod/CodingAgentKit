import AgentCore
import Foundation

/// The floor under both generations of opencode's wire. opencode 1.x and 2.x share nothing on
/// the wire — every route moved and every event was renamed — but they share the machine: the
/// same restart command the setup script leaves behind, the same attachment bytes, the same
/// slash words this Kit carries out itself. Those live here once so the two backends cannot
/// drift apart on them.
enum OpenCodeCommon {
    /// The command the setup script leaves on the machine for exactly this, named once so the
    /// client and the installer cannot drift apart on it.
    static let restartCommand = "opencode-serve-restart"

    static var restartInvocation: String { #"exec "$HOME/.local/bin/\#(restartCommand)""# }

    static var installInvocation: String {
        #"curl -fsSL https://raw.githubusercontent.com/guitaripod/Tailscode/master/scripts/opencode-serve-install.sh | bash"#
    }

    /// The built-in slash words this Kit can execute for an opencode server. `compact` carries no
    /// argument hint because `supportsCompactionInstructions` is false here — the server decides
    /// what its summary keeps, and promising a place to say otherwise would be a lie.
    static let builtins: [AgentCommand] = [
        AgentCommand(
            name: "compact",
            details: "Summarize the conversation so far to free up context",
            argumentHint: nil,
            source: .builtin)
    ]

    /// opencode publishes `summarize` as `compact`'s own alias, so both spellings reach the same
    /// route rather than one of them going out to the model as the word it was typed as.
    static func isCompaction(_ name: String) -> Bool {
        name == "compact" || name == "summarize"
    }

    /// opencode embeds attachment bytes straight into the file part's URL as a
    /// data: URI — the server synthesizes `data:<mime>;base64,<bytes>` when a
    /// tool result carries a file — so no bridge round-trip is needed: decode
    /// locally. A `file://` URL (what @-mentioned text files use) is read from
    /// local disk where the path exists, i.e. desktop clients; on iOS it fails
    /// harmlessly and the row falls back to a plain file chip.
    static func attachmentData(_ file: FileReference) throws -> Data {
        if let url = file.url {
            if let decoded = dataURLBytes(url) { return decoded }
            if url.hasPrefix("file://") {
                let path = String(url.dropFirst("file://".count))
                let decoded = path.removingPercentEncoding ?? path
                if let data = try? Data(contentsOf: URL(fileURLWithPath: decoded)) {
                    return data
                }
            }
        }
        if let path = file.path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return data
        }
        throw AgentError.unsupported("attachment without embedded data")
    }

    static func dataURLBytes(_ url: String) -> Data? {
        guard url.hasPrefix("data:") else { return nil }
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
        let payload = String(url[url.index(after: comma)...])
        if header.hasSuffix(";base64") {
            let cleaned = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned)
        }
        return Data((payload.removingPercentEncoding ?? payload).utf8)
    }

    /// The menu wants ascending effort. Known effort names sort by rank, anything else lands
    /// after them alphabetically.
    static func orderedVariants(_ names: [String]) -> [String]? {
        guard !names.isEmpty else { return nil }
        let rank = ["minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5]
        return names.sorted {
            switch (rank[$0], rank[$1]) {
            case let (.some(a), .some(b)): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0 < $1
            }
        }
    }

    typealias Spawn = @Sendable (_ command: String, _ args: [String], _ title: String) async throws
        -> String
    typealias PtyIDs = @Sendable () async throws -> [String]

    /// opencode has no restart route — a process cannot be asked to replace itself over its own
    /// API. What it does have is a pty, and the machine has a supervisor, so the restart is run on
    /// the server by the server: one command, the one the setup script leaves behind for exactly
    /// this, reached through the login shell so it does not depend on what PATH a service happened
    /// to inherit.
    ///
    /// Then it is checked, because a restart that quietly did nothing is the one outcome nobody
    /// can act on. A pty outlives the command it ran, so the pty this spawned is still listed by
    /// the process that spawned it — and stops being listed, or stops answering at all, exactly
    /// when that process has gone. A machine with no such command keeps its pty and is told so in
    /// a sentence that says what to do about it.
    static func restart(spawn: Spawn, ptyIDs: PtyIDs) async throws {
        guard try await restartWorks(spawn: spawn, ptyIDs: ptyIDs) else {
            throw AgentError.unsupported(
                "This server was not set up for restarts. Re-run the opencode setup command on that machine."
            )
        }
    }

    private static let restartChecks = 10
    private static let restartCheckInterval: Duration = .seconds(1)

    /// Spawns the restart and watches for this process's ptys to go with it. A `nil` answer is a
    /// server that just restarted — the ask provably took.
    static func restartWorks(spawn: Spawn, ptyIDs: PtyIDs) async throws -> Bool {
        let pty = try await spawn("sh", ["-lc", restartInvocation], "restart")
        for _ in 0..<restartChecks {
            try? await Task.sleep(for: restartCheckInterval)
            guard let ptys = try? await ptyIDs() else { return true }
            guard ptys.contains(pty) else { return true }
        }
        return false
    }

    private static let installChecks = 60
    private static let installCheckInterval: Duration = .seconds(2)

    /// The whole setup, run on the machine by the machine: opencode if it is missing, the
    /// supervisor that survives a reboot, the restart command, and the check that restarts the
    /// server when its model list changes. The installer may replace the very process answering
    /// this ask — a machine whose own supervisor takes the port boots the hand-run server out — so
    /// the answer is read from the machine after, not awaited in flight: once it answers and
    /// provably restarts, the setup has taken.
    static func installServeManager(spawn: Spawn, ptyIDs: PtyIDs) async throws {
        _ = try await spawn("sh", ["-lc", installInvocation], "set up server")
        for _ in 0..<installChecks {
            try? await Task.sleep(for: installCheckInterval)
            guard (try? await ptyIDs()) != nil else { continue }
            if try await restartWorks(spawn: spawn, ptyIDs: ptyIDs) { return }
            break
        }
        throw AgentError.unsupported(
            "The setup did not take. Run the opencode setup command on that machine by hand.")
    }
}

/// The events this Kit raises itself, put on the session's own stream so a client reads them
/// exactly like the server's.
///
/// opencode answers a command only once the turn it started has ended, so a command is
/// dispatched rather than awaited — and a dispatch that fails then has no reply channel at all.
/// A compaction that never started used to be a line in a log file: the preflight closed, the
/// spinner stopped and the transcript sat exactly as it was, which reads as the app ignoring
/// the request. It says so here instead.
actor OpenCodeLocalEvents {
    private var listeners:
        [String: [UUID: AsyncThrowingStream<BackendEvent, Error>.Continuation]] = [:]

    func listen(
        _ sessionID: String,
        _ continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation
    ) -> UUID {
        let token = UUID()
        listeners[sessionID, default: [:]][token] = continuation
        return token
    }

    func drop(_ sessionID: String, _ token: UUID) {
        listeners[sessionID]?.removeValue(forKey: token)
        if listeners[sessionID]?.isEmpty == true { listeners[sessionID] = nil }
    }

    func send(_ event: BackendEvent, to sessionID: String) {
        guard let slots = listeners[sessionID] else { return }
        for continuation in slots.values { continuation.yield(event) }
    }
}

/// One generation of opencode's wire, whole: everything a client may ask of an opencode server,
/// answered by the code that speaks that server's own routes. ``OpenCodeBackend`` finds out which
/// generation a server is and hands every call to the one that fits.
protocol OpenCodeGeneration: FileBrowsingBackend, RestartableBackend, GitObservingBackend,
    ServeManagerBackend, SessionListStreaming
{}
