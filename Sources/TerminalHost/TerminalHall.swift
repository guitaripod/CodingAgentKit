#if os(macOS) || os(Linux)
    import Foundation
    import TerminalWire

    /// Every shell a server is holding.
    ///
    /// A shell stays for as long as it is doing something or somebody may come back to it: one
    /// with a command running is never closed for being unwatched, one waiting at its prompt with
    /// nobody reading is closed after `idleLifetime`, and one that has ended is forgotten shortly
    /// after, once any reader has had the chance to hear how.
    public final class TerminalHall: @unchecked Sendable {
        public struct Policy: Sendable {
            public var limit = 16
            public var idleLifetime: TimeInterval = 12 * 3600
            public var endedLinger: TimeInterval = 60
            public var ringBytes = 4 << 20
            /// Names in the server's environment a shell must not inherit: the server's own secrets.
            public var secrets: Set<String> = []

            public init() {}
        }

        private let policy: Policy
        private let lock = NSLock()
        private var seats: [String: TerminalSeat] = [:]
        private var sweeper: DispatchSourceTimer?

        public init(policy: Policy = Policy()) {
            self.policy = policy
        }

        deinit {
            sweeper?.cancel()
        }

        public func open(_ request: TerminalOpenRequest) throws -> TerminalSeat {
            sweep()
            let running = lock.withLock { seats.values.filter(\.isRunning).count }
            guard running < policy.limit else { throw TerminalHostError.tooMany(policy.limit) }
            let shell = ShellEnvironment.loginShell()
            let directory = Self.startingDirectory(request.directory)
            let size = TerminalSize.clamped(cols: request.cols, rows: request.rows)
            let process = try PtyProcess.spawn(
                shell: shell, directory: directory,
                environment: ShellEnvironment.compose(
                    shell: shell, directory: directory, scrubbing: policy.secrets),
                cols: size.cols, rows: size.rows)
            let seat = TerminalSeat(
                id: UUID().uuidString.lowercased(), session: request.session, desk: request.desk,
                process: process, cols: size.cols, rows: size.rows, ringBytes: policy.ringBytes)
            lock.withLock {
                seats[seat.id] = seat
                if sweeper == nil { startSweeper() }
            }
            return seat
        }

        /// The folder asked for when it is one, else home: a conversation whose folder has been
        /// deleted since still gets a shell.
        static func startingDirectory(_ asked: String?) -> String? {
            var isDirectory: ObjCBool = false
            if let asked, !asked.isEmpty {
                let path = (asked as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return path
                }
            }
            let home = NSHomeDirectory()
            return FileManager.default.fileExists(atPath: home, isDirectory: &isDirectory) && isDirectory.boolValue
                ? home : nil
        }

        public func seat(_ id: String) -> TerminalSeat? {
            lock.withLock { seats[id] }
        }

        public func list() -> [TerminalInfo] {
            let all = lock.withLock { Array(seats.values) }
            return all.map { $0.info() }.sorted { $0.startedAt < $1.startedAt }
        }

        /// Ends a shell and forgets it. False when there was no such shell.
        @discardableResult
        public func close(_ id: String) -> Bool {
            guard let seat = lock.withLock({ seats.removeValue(forKey: id) }) else { return false }
            seat.end()
            return true
        }

        /// How many shells have a command running in front of them.
        public func busyCount() -> Int {
            let all = lock.withLock { Array(seats.values) }
            return all.filter(\.isBusy).count
        }

        public func closeAll() {
            let all = lock.withLock {
                let all = Array(seats.values)
                seats.removeAll()
                return all
            }
            all.forEach { $0.end() }
        }

        private func startSweeper() {
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in self?.sweep() }
            timer.resume()
            sweeper = timer
        }

        func sweep(now: Date = Date()) {
            let all = lock.withLock { Array(seats.values) }
            for seat in all {
                if let ended = seat.exited {
                    if now.timeIntervalSince(ended) > policy.endedLinger, seat.idleSince != nil {
                        lock.withLock { _ = seats.removeValue(forKey: seat.id) }
                    }
                } else if let idle = seat.idleSince, now.timeIntervalSince(idle) > policy.idleLifetime,
                    !seat.isBusy
                {
                    close(seat.id)
                }
            }
        }
    }
#endif
