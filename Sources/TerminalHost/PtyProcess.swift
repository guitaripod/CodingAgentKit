#if os(macOS) || os(Linux)
    import Foundation

    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Darwin)
        import Darwin
    #endif

    /// Why a shell could not be started, in words a person can be shown.
    public enum TerminalHostError: Error, Sendable, Equatable, CustomStringConvertible {
        case tooMany(Int)
        case noPseudoTerminal(String)
        case shellDidNotStart(String, String)

        public var description: String {
            switch self {
            case .tooMany(let limit):
                return "That machine already has \(limit) terminals open. Close one to open another."
            case .noPseudoTerminal(let reason):
                return "That machine could not make a terminal: \(reason)."
            case .shellDidNotStart(let shell, let reason):
                return "That machine could not start \(shell): \(reason)."
            }
        }
    }

    /// A shell running on a pseudo-terminal this process owns.
    ///
    /// The shell is started with `posix_spawn`, never `fork`: a server with a dozen threads cannot
    /// safely run its own code in a forked child. Everything a login on a real terminal gets is
    /// asked of the kernel instead: a session of its own, the pseudo-terminal as that session's
    /// controlling terminal (the first terminal a session leader opens becomes one), default
    /// signals, and no descriptor of the server's but its three. The shell's end is held open
    /// here until the shell has it, because a size given to a pseudo-terminal nobody has opened
    /// yet is forgotten on a Mac.
    final class PtyProcess: @unchecked Sendable {
        let pid: pid_t
        let master: Int32
        let shellPath: String

        private init(pid: pid_t, master: Int32, shellPath: String) {
            self.pid = pid
            self.master = master
            self.shellPath = shellPath
        }

        var shellName: String { (shellPath as NSString).lastPathComponent }

        private static let spawnLock = NSLock()

        static func spawn(
            shell: String, directory: String?, environment: [String: String], cols: Int, rows: Int
        ) throws -> PtyProcess {
            try spawnLock.withLock {
                let (master, slave) = try openPair()
                _ = fcntl(master, F_SETFD, FD_CLOEXEC)
                _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
                let held = open(slave, O_RDWR | O_NOCTTY | O_CLOEXEC)
                defer { if held >= 0 { close(held) } }
                setSize(held >= 0 ? held : master, cols: cols, rows: rows)

                let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-" + (shell as NSString).lastPathComponent), nil]
                let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
                defer {
                    argv.forEach { free($0) }
                    envp.forEach { free($0) }
                }
                #if os(macOS)
                    var actions: posix_spawn_file_actions_t?
                    var attributes: posix_spawnattr_t?
                #else
                    var actions = posix_spawn_file_actions_t()
                    var attributes = posix_spawnattr_t()
                #endif
                posix_spawn_file_actions_init(&actions)
                posix_spawnattr_init(&attributes)
                defer {
                    posix_spawn_file_actions_destroy(&actions)
                    posix_spawnattr_destroy(&attributes)
                }
                posix_spawn_file_actions_addopen(&actions, 0, slave, O_RDWR, 0)
                posix_spawn_file_actions_adddup2(&actions, 0, 1)
                posix_spawn_file_actions_adddup2(&actions, 0, 2)
                var everySignal = sigset_t()
                var noSignal = sigset_t()
                sigfillset(&everySignal)
                sigemptyset(&noSignal)
                posix_spawnattr_setsigdefault(&attributes, &everySignal)
                posix_spawnattr_setsigmask(&attributes, &noSignal)
                #if os(macOS)
                    if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory) }
                    let flags =
                        POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                        | POSIX_SPAWN_CLOEXEC_DEFAULT
                #else
                    if let directory, let addChdir = SpawnExtensions.addChdir { _ = addChdir(&actions, directory) }
                    if let closeFrom = SpawnExtensions.closeFrom { _ = closeFrom(&actions, 3) }
                    let flags = SpawnExtensions.setSession | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                #endif
                posix_spawnattr_setflags(&attributes, Int16(truncatingIfNeeded: flags))
                var pid: pid_t = 0
                let result = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
                guard result == 0 else {
                    close(master)
                    throw TerminalHostError.shellDidNotStart(
                        (shell as NSString).lastPathComponent, String(cString: strerror(result)))
                }
                return PtyProcess(pid: pid, master: master, shellPath: shell)
            }
        }

        private static func lastError() -> String { String(cString: strerror(errno)) }

        /// A new pseudo-terminal: the end this process keeps, and the path of the end the shell
        /// will open.
        private static func openPair() throws -> (master: Int32, slave: String) {
            #if os(macOS)
                let master = posix_openpt(O_RDWR | O_NOCTTY)
                guard master >= 0 else { throw TerminalHostError.noPseudoTerminal(lastError()) }
                guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
                    let reason = lastError()
                    close(master)
                    throw TerminalHostError.noPseudoTerminal(reason)
                }
                return (master, String(cString: name))
            #else
                guard let open = SpawnExtensions.openTerminal, let grant = SpawnExtensions.grant,
                    let unlock = SpawnExtensions.unlock, let nameOf = SpawnExtensions.name
                else { throw TerminalHostError.noPseudoTerminal("this system has no pseudo-terminals") }
                let master = open(O_RDWR | O_NOCTTY)
                guard master >= 0 else { throw TerminalHostError.noPseudoTerminal(lastError()) }
                var name = [CChar](repeating: 0, count: 128)
                guard grant(master) == 0, unlock(master) == 0, nameOf(master, &name, name.count) == 0 else {
                    let reason = lastError()
                    close(master)
                    throw TerminalHostError.noPseudoTerminal(reason)
                }
                let path = name.withUnsafeBufferPointer { raw in
                    String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                return (master, path)
            #endif
        }

        static func setSize(_ descriptor: Int32, cols: Int, rows: Int) {
            var size = winsize(
                ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(descriptor, PtyRequests.setWindowSize, &size)
        }

        func resize(cols: Int, rows: Int) {
            Self.setSize(master, cols: cols, rows: rows)
        }

        /// The process group reading the keyboard: the shell's own while it waits at its prompt,
        /// a job's while one runs in front of it.
        var foregroundGroup: pid_t? {
            let group = tcgetpgrp(master)
            return group > 0 ? group : nil
        }

        /// The program in front of the shell, absent while the shell itself is in front.
        var job: String? {
            guard let group = foregroundGroup, group != pid else { return nil }
            return ProcessFacts.name(of: group) ?? "a command"
        }

        var directory: String? { ProcessFacts.directory(of: pid) }

        /// Tells whatever is drawing in front of the shell to draw again, the way a resized window
        /// does: a full-screen program a reader joins halfway through has no other reason to.
        func askForRedraw() {
            guard let group = foregroundGroup, group != pid else { return }
            kill(-group, SIGWINCH)
        }

        /// Hangs up, the way closing a terminal window does, and makes sure of it a moment later.
        func hangUp() {
            let shell = pid
            let front = foregroundGroup
            if let front, front != shell { kill(-front, SIGHUP) }
            kill(-shell, SIGHUP)
            kill(-shell, SIGCONT)
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if let front, front != shell, kill(-front, 0) == 0 { kill(-front, SIGKILL) }
                if kill(-shell, 0) == 0 { kill(-shell, SIGKILL) }
            }
        }

        /// Waits for the shell to end and answers the status a shell would report for it.
        func waitForExit() -> Int {
            var status: Int32 = 0
            var reaped = waitpid(pid, &status, 0)
            while reaped == -1, errno == EINTR { reaped = waitpid(pid, &status, 0) }
            guard reaped == pid else { return -1 }
            let signal = status & 0x7f
            return Int(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        }
    }

    enum PtyRequests {
        #if os(macOS)
            static let setWindowSize: UInt = 0x8008_7467
        #else
            static let setWindowSize = UInt(TIOCSWINSZ)
        #endif
    }

    #if !os(macOS)
        /// glibc's spawn additions, found at run time: Swift's Glibc module shows them only where
        /// the headers were read with GNU extensions on. A glibc too old for one of them starts
        /// the shell at home, or with the server's descriptors still open, rather than not at all.
        enum SpawnExtensions {
            typealias AddChdir = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, UnsafePointer<CChar>) -> Int32
            typealias CloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>, Int32) -> Int32

            typealias OpenTerminal = @convention(c) (Int32) -> Int32
            typealias OnDescriptor = @convention(c) (Int32) -> Int32
            typealias NameOf = @convention(c) (Int32, UnsafeMutablePointer<CChar>, Int) -> Int32

            static let setSession: Int32 = 0x80
            static let openTerminal: OpenTerminal? = symbol("posix_openpt")
            static let grant: OnDescriptor? = symbol("grantpt")
            static let unlock: OnDescriptor? = symbol("unlockpt")
            static let name: NameOf? = symbol("ptsname_r")
            static let addChdir: AddChdir? = symbol("posix_spawn_file_actions_addchdir_np")
            static let closeFrom: CloseFrom? = symbol("posix_spawn_file_actions_addclosefrom_np")

            private static func symbol<T>(_ name: String) -> T? {
                guard let found = dlsym(UnsafeMutableRawPointer(bitPattern: 0), name) else { return nil }
                return unsafeBitCast(found, to: T.self)
            }
        }
    #endif

    /// What the kernel says about a process this user owns.
    enum ProcessFacts {
        static func directory(of pid: pid_t) -> String? {
            #if os(macOS)
                var info = proc_vnodepathinfo()
                let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
                let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                return path.isEmpty ? nil : path
            #else
                guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd"),
                    link.hasPrefix("/")
                else { return nil }
                return link.hasSuffix(" (deleted)") ? String(link.dropLast(10)) : link
            #endif
        }

        static func name(of pid: pid_t) -> String? {
            #if os(macOS)
                var buffer = [CChar](repeating: 0, count: 256)
                guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
                let name = buffer.withUnsafeBufferPointer { raw in
                    String(decoding: raw.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                return name.isEmpty ? nil : name
            #else
                guard let raw = try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return nil }
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : name
            #endif
        }
    }

    /// The shell a person gets and the world it starts in.
    public enum ShellEnvironment {
        /// The account's own login shell, the one a terminal window on that machine would start.
        public static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
            var candidates: [String] = []
            if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
                candidates.append(String(cString: shell))
            }
            if let named = environment["SHELL"] { candidates.append(named) }
            #if os(macOS)
                candidates += ["/bin/zsh", "/bin/bash", "/bin/sh"]
            #else
                candidates += ["/bin/bash", "/bin/sh"]
            #endif
            return candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/sh"
        }

        static let supervisorKeys: Set<String> = [
            "NOTIFY_SOCKET", "JOURNAL_STREAM", "INVOCATION_ID", "SYSTEMD_EXEC_PID", "MANAGERPID",
            "WATCHDOG_USEC", "WATCHDOG_PID", "MEMORY_PRESSURE_WATCH", "MEMORY_PRESSURE_WRITE",
            "XPC_SERVICE_NAME", "XPC_FLAGS",
        ]

        /// What the shell is started with: the server's own environment without what belongs to
        /// the server (its secrets, its supervisor's handles), plus what makes it a terminal.
        public static func compose(
            base: [String: String] = ProcessInfo.processInfo.environment, shell: String,
            directory: String?, scrubbing secrets: Set<String>
        ) -> [String: String] {
            var environment = base.filter { !secrets.contains($0.key) && !supervisorKeys.contains($0.key) }
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["TERM_PROGRAM"] = "Tailscode"
            environment["SHELL"] = shell
            if let entry = getpwuid(getuid()) {
                if environment["HOME"] == nil, let home = entry.pointee.pw_dir {
                    environment["HOME"] = String(cString: home)
                }
                if let name = entry.pointee.pw_name {
                    let user = String(cString: name)
                    if environment["USER"] == nil { environment["USER"] = user }
                    if environment["LOGNAME"] == nil { environment["LOGNAME"] = user }
                }
            }
            if environment["LANG"] == nil, environment["LC_ALL"] == nil, environment["LC_CTYPE"] == nil {
                #if os(macOS)
                    environment["LANG"] = "en_US.UTF-8"
                #else
                    environment["LANG"] = "C.UTF-8"
                #endif
            }
            if let directory { environment["PWD"] = directory } else { environment["PWD"] = nil }
            environment["OLDPWD"] = nil
            return environment
        }
    }
#endif
