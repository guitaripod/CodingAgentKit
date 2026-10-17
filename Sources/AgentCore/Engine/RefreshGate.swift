import Foundation

/// How soon a conversation's transcript refetch should go out when several are waiting.
public enum RefreshPriority: Int, Sendable, Comparable {
    /// A conversation nobody is looking at, kept alive to follow a turn.
    case background = 0
    case normal = 1
    /// The conversation on screen.
    case foreground = 2

    public static func < (lhs: RefreshPriority, rhs: RefreshPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A conversation's current ``RefreshPriority``, readable from anywhere and changeable while its
/// refetch is already waiting for a turn.
final class RefreshPriorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RefreshPriority = .normal

    var priority: RefreshPriority {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// How many transcript refetches a process runs at once.
///
/// Every conversation a process holds re-reads its transcript when its stream notices a gap, and a
/// process that stalls for longer than the stream tolerates notices it in all of them in the same
/// instant: each refetch is the whole conversation, megabytes to decode and rebuild, so a dozen
/// at once is a pause nobody asked for. The gate lets a few through and hands the next turn to the
/// highest priority waiting, the longest waiting among equals.
///
/// A turn is a lease rather than a possession: a read that has not finished after `lease` stops
/// counting against the limit, so a server that has gone quiet holds up the conversations of
/// every other server for that long and no longer.
final class RefreshGate: @unchecked Sendable {
    static let shared = RefreshGate(limit: 2, lease: .seconds(20))

    /// One admitted refetch's turn. Releasing it twice, or letting the lease lapse and then
    /// releasing it, gives back exactly one turn.
    final class Permit: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: RefreshGate?
        private var lapse: Task<Void, Never>?

        fileprivate init(gate: RefreshGate, lease: Duration) {
            self.gate = gate
            lapse = Task { [weak self] in
                try? await Task.sleep(for: lease)
                guard !Task.isCancelled else { return }
                self?.release()
            }
        }

        func release() {
            let held = lock.withLock { () -> (RefreshGate, Task<Void, Never>?)? in
                guard let gate else { return nil }
                self.gate = nil
                return (gate, lapse)
            }
            held?.1?.cancel()
            held?.0.giveBack()
        }
    }

    private struct Waiter {
        let id: UInt64
        let priority: RefreshPriorityBox
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private let lease: Duration
    private let lock = NSLock()
    private var running = 0
    private var nextID: UInt64 = 0
    private var waiters: [Waiter] = []

    init(limit: Int, lease: Duration = .seconds(20)) {
        self.limit = limit
        self.lease = lease
    }

    var runningCount: Int { lock.withLock { running } }

    var waitingCount: Int { lock.withLock { waiters.count } }

    /// Waits for a turn and holds it until the permit is released or its lease lapses. Throws if
    /// the caller is cancelled while waiting, in which case no turn is held.
    func acquire(priority: RefreshPriorityBox) async throws -> Permit {
        let id = lock.withLock { () -> UInt64 in
            nextID += 1
            return nextID
        }
        try await waitForTurn(id: id, priority: priority)
        return Permit(gate: self, lease: lease)
    }

    private func waitForTurn(id: UInt64, priority: RefreshPriorityBox) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome = lock.withLock { () -> Result<Bool, CancellationError> in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if running < limit {
                        running += 1
                        return .success(true)
                    }
                    waiters.append(Waiter(id: id, priority: priority, continuation: continuation))
                    return .success(false)
                }
                switch outcome {
                case .success(true): continuation.resume()
                case .success(false): break
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> Waiter? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    fileprivate func giveBack() {
        let next = lock.withLock { () -> Waiter? in
            guard !waiters.isEmpty else {
                running -= 1
                return nil
            }
            var best = 0
            for index in waiters.indices.dropFirst()
            where waiters[index].priority.priority > waiters[best].priority.priority {
                best = index
            }
            return waiters.remove(at: best)
        }
        next?.continuation.resume()
    }
}
