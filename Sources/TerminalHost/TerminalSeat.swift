#if os(macOS) || os(Linux)
    import Foundation
    import TerminalWire

    #if canImport(Glibc)
        import Glibc
    #elseif canImport(Darwin)
        import Darwin
    #endif

    /// One shell a server is holding, and everyone reading it.
    ///
    /// A thread of its own reads the shell into the ring whether or not anyone is watching, so a
    /// program that prints a gigabyte is never slowed by a reader on a train, and a reader that
    /// cannot keep up is not sent the gigabyte: it reads from the ring at its own pace and, once
    /// the ring has moved past it, is started over at the ring's oldest safe place.
    public final class TerminalSeat: @unchecked Sendable {
        public let id: String
        public let session: String?
        public let desk: String?
        public let startedAt = Date()

        private let process: PtyProcess
        private let lock = NSLock()
        private var ring: TerminalRing
        private var cols: Int
        private var rows: Int
        private var exitCode: Int?
        private var exitedAt: Date?
        private var readerDone = false
        private var readers: [UUID: AsyncStream<Void>.Continuation] = [:]
        private var lastTouched = Date()
        private var wake: [Int32] = [-1, -1]
        private let writes = DispatchQueue(label: "terminal.write")
        private var queuedInput = 0
        private var ticker: DispatchSourceTimer?

        static let inputBacklog = 4 << 20

        init(
            id: String, session: String?, desk: String?, process: PtyProcess, cols: Int, rows: Int,
            ringBytes: Int
        ) {
            self.id = id
            self.session = session
            self.desk = desk
            self.process = process
            self.cols = cols
            self.rows = rows
            self.ring = TerminalRing(limit: ringBytes)
            _ = pipe(&wake)
            for descriptor in wake {
                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
            }
            let reader = Thread { [self] in readLoop() }
            reader.name = "terminal.read"
            reader.stackSize = 256 << 10
            reader.start()
            let waiter = Thread { [self] in
                let code = process.waitForExit()
                shellEnded(code)
            }
            waiter.name = "terminal.wait"
            waiter.stackSize = 128 << 10
            waiter.start()
        }

        deinit {
            for descriptor in wake where descriptor >= 0 { close(descriptor) }
            close(process.master)
        }

        /// Drains the shell into the ring until the shell is gone and has nothing left to say.
        private func readLoop() {
            let capacity = 64 << 10
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            defer { buffer.deallocate() }
            var descriptors = [
                pollfd(fd: process.master, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wake[0], events: Int16(POLLIN), revents: 0),
            ]
            var draining = false
            while true {
                let ready = poll(&descriptors, 2, draining ? 0 : -1)
                if ready < 0, errno == EINTR { continue }
                if descriptors[1].revents != 0 {
                    var scratch = [UInt8](repeating: 0, count: 16)
                    while read(wake[0], &scratch, scratch.count) > 0 {}
                    draining = true
                }
                var readSomething = false
                while true {
                    let count = read(process.master, buffer, capacity)
                    if count > 0 {
                        readSomething = true
                        let chunk = UnsafeRawBufferPointer(start: buffer, count: count)
                        lock.withLock { ring.append(chunk) }
                        notify()
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { break }
                    draining = true
                    readSomething = false
                    break
                }
                if draining, !readSomething { break }
            }
            lock.withLock { readerDone = true }
            notify()
        }

        private func shellEnded(_ code: Int) {
            lock.withLock {
                exitCode = code
                exitedAt = Date()
            }
            notify()
            Thread.sleep(forTimeInterval: 0.15)
            stopReading()
        }

        private func stopReading() {
            var byte: UInt8 = 1
            _ = write(wake[1], &byte, 1)
        }

        private func notify() {
            let waiting = lock.withLock { Array(readers.values) }
            for reader in waiting { reader.yield() }
        }

        public func info() -> TerminalInfo {
            let (cols, rows, exitCode, attached, offset) = lock.withLock {
                (self.cols, self.rows, self.exitCode, readers.count, ring.endOffset)
            }
            let running = exitCode == nil
            return TerminalInfo(
                id: id, shell: process.shellName, directory: running ? process.directory : nil,
                job: running ? process.job : nil, cols: cols, rows: rows, startedAt: startedAt,
                session: session, desk: desk, exitCode: exitCode, attached: attached, offset: offset)
        }

        public var isRunning: Bool { lock.withLock { exitCode == nil } }

        /// Whether something is running in front of the shell: work a restart would destroy.
        public var isBusy: Bool { isRunning && process.job != nil }

        var exited: Date? { lock.withLock { exitedAt } }

        var idleSince: Date? { lock.withLock { readers.isEmpty ? lastTouched : nil } }

        /// What a person typed, in the order it was typed. A shell that has stopped reading holds
        /// up only its own input, on its own queue, and only so much of it.
        public func send(_ data: Data) {
            guard !data.isEmpty else { return }
            let accepted: Bool = lock.withLock {
                guard exitCode == nil, queuedInput + data.count <= Self.inputBacklog else { return false }
                queuedInput += data.count
                lastTouched = Date()
                return true
            }
            guard accepted else { return }
            writes.async { [self] in
                defer { lock.withLock { queuedInput -= data.count } }
                writeAll(data)
            }
        }

        private func writeAll(_ data: Data) {
            let deadline = Date().addingTimeInterval(20)
            data.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = write(process.master, raw.baseAddress! + sent, raw.count - sent)
                    if count > 0 {
                        sent += count
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK, Date() < deadline,
                        lock.withLock({ exitCode == nil })
                    else { return }
                    var waiting = pollfd(fd: process.master, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&waiting, 1, 200)
                }
            }
        }

        public func resize(cols: Int, rows: Int) {
            let size = TerminalSize.clamped(cols: cols, rows: rows)
            let changed: Bool = lock.withLock {
                guard self.cols != size.cols || self.rows != size.rows else { return false }
                self.cols = size.cols
                self.rows = size.rows
                return true
            }
            if changed {
                process.resize(cols: size.cols, rows: size.rows)
                notify()
            }
        }

        /// Ends the shell the way closing a terminal window does.
        public func end() {
            guard isRunning else { return }
            process.hangUp()
        }

        /// The terminal's output from `offset` on, as frames ready to send, for as long as the
        /// caller keeps asking. Asking for no position, or for one the ring has let go of, starts
        /// the reader over.
        public func feed(from offset: UInt64?) -> TerminalFeed {
            TerminalFeed(seat: self, from: offset)
        }

        func join() -> (UUID, AsyncStream<Void>) {
            let key = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            lock.withLock {
                readers[key] = continuation
                lastTouched = Date()
                if ticker == nil { startTicker() }
            }
            return (key, stream)
        }

        func leave(_ key: UUID) {
            lock.withLock {
                readers.removeValue(forKey: key)?.finish()
                lastTouched = Date()
                if readers.isEmpty {
                    ticker?.cancel()
                    ticker = nil
                }
            }
        }

        /// Wakes every reader once a second while there are readers, which is what lets one say
        /// the shell changed folder or that the connection is still alive during a long silence.
        private func startTicker() {
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.notify() }
            timer.resume()
            ticker = timer
        }

        enum Step {
            case start(TerminalStart, preamble: Data, redraw: Bool)
            case output(Data)
            case ended(Int?)
            case idle
        }

        /// What a reader at `cursor` is owed next. A cursor of nil is a reader that has nothing.
        func step(cursor: UInt64?, limit: Int) -> (Step, UInt64) {
            let result: (Step, UInt64) = lock.withLock {
                guard let cursor, let data = ring.read(from: cursor, limit: limit) else {
                    let replay = ring.replayStart()
                    let start = TerminalStart(offset: replay.offset, reset: true, cols: cols, rows: rows)
                    return (.start(start, preamble: replay.preamble, redraw: exitCode == nil), replay.offset)
                }
                if !data.isEmpty { return (.output(data), cursor + UInt64(data.count)) }
                if readerDone, exitCode != nil { return (.ended(exitCode), cursor) }
                return (.idle, cursor)
            }
            return result
        }

        func size() -> (cols: Int, rows: Int) { lock.withLock { (cols, rows) } }

        func askForRedraw() { process.askForRedraw() }
    }

    /// One reader's view of a terminal: an endless sequence of encoded frames.
    ///
    /// It is pulled, never pushed. Nothing is prepared for a reader until the reader asks for its
    /// next piece, so a slow connection holds nothing in memory but its own position.
    public struct TerminalFeed: AsyncSequence, Sendable {
        public typealias Element = Data

        let seat: TerminalSeat
        let from: UInt64?

        public func makeAsyncIterator() -> Iterator {
            Iterator(seat: seat, from: from)
        }

        public final class Iterator: AsyncIteratorProtocol {
            private let seat: TerminalSeat
            private var cursor: UInt64?
            private var started = false
            private var finished = false
            private var pendingRedraw = false
            private var key: UUID?
            private var wakes: AsyncStream<Void>.Iterator?
            private var lastState: TerminalInfo?
            private var lastStateCheck = Date.distantPast
            private var lastSent = Date()

            static let chunk = 64 << 10
            static let pingAfter: TimeInterval = 15

            init(seat: TerminalSeat, from: UInt64?) {
                self.seat = seat
                self.cursor = from
            }

            deinit {
                if let key { seat.leave(key) }
            }

            public func next() async -> Data? {
                if finished { return nil }
                if key == nil {
                    let (key, stream) = seat.join()
                    self.key = key
                    wakes = stream.makeAsyncIterator()
                }
                while !Task.isCancelled {
                    if !started {
                        started = true
                        return begin()
                    }
                    let (step, next) = seat.step(cursor: cursor, limit: Self.chunk)
                    cursor = next
                    switch step {
                    case .start(let start, let preamble, let redraw):
                        pendingRedraw = redraw
                        return sent(TerminalFrame.start(start).encoded() + Self.output(preamble))
                    case .output(let data):
                        return sent(TerminalFrame.output(data).encoded())
                    case .ended(let code):
                        finished = true
                        return TerminalFrame.exit(TerminalExit(code: code)).encoded()
                    case .idle:
                        if pendingRedraw {
                            pendingRedraw = false
                            seat.askForRedraw()
                        }
                        if let frame = stateIfChanged() { return sent(frame) }
                        if Date().timeIntervalSince(lastSent) >= Self.pingAfter {
                            return sent(TerminalFrame.ping.encoded())
                        }
                        guard var waiting = wakes else { return nil }
                        let woken: Void? = await waiting.next()
                        wakes = waiting
                        if woken == nil { return nil }
                    }
                }
                return nil
            }

            /// The first thing a reader is told: where it stands. A reader that asked to go on
            /// from a position the ring still holds goes on; any other reader is started over.
            private func begin() -> Data {
                let size = seat.size()
                if let cursor {
                    let (step, next) = seat.step(cursor: cursor, limit: 0)
                    if case .start(let start, let preamble, let redraw) = step {
                        self.cursor = next
                        pendingRedraw = redraw
                        return sent(TerminalFrame.start(start).encoded() + Self.output(preamble) + state())
                    }
                    let start = TerminalStart(offset: cursor, reset: false, cols: size.cols, rows: size.rows)
                    return sent(TerminalFrame.start(start).encoded() + state())
                }
                let (step, next) = seat.step(cursor: nil, limit: 0)
                cursor = next
                guard case .start(let start, let preamble, let redraw) = step else {
                    let start = TerminalStart(offset: next, reset: true, cols: size.cols, rows: size.rows)
                    return sent(TerminalFrame.start(start).encoded() + state())
                }
                pendingRedraw = redraw
                return sent(TerminalFrame.start(start).encoded() + Self.output(preamble) + state())
            }

            private static func output(_ bytes: Data) -> Data {
                bytes.isEmpty ? Data() : TerminalFrame.output(bytes).encoded()
            }

            private func state() -> Data {
                let info = seat.info()
                lastState = Self.comparable(info)
                lastStateCheck = Date()
                return TerminalFrame.state(info).encoded()
            }

            private func stateIfChanged() -> Data? {
                guard Date().timeIntervalSince(lastStateCheck) >= 0.5 else { return nil }
                lastStateCheck = Date()
                let info = seat.info()
                let comparable = Self.comparable(info)
                guard comparable != lastState else { return nil }
                lastState = comparable
                return TerminalFrame.state(info).encoded()
            }

            /// A reading with the parts that change on every byte taken out, so a state frame is
            /// sent when something a person would notice changed and not for every line printed.
            private static func comparable(_ info: TerminalInfo) -> TerminalInfo {
                var copy = info
                copy.offset = 0
                copy.attached = 0
                return copy
            }

            private func sent(_ data: Data) -> Data {
                lastSent = Date()
                return data
            }
        }
    }
#endif
