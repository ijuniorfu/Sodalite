import Foundation

/// FIFO counting semaphore for async/await; caps HTTPClient in-flight requests so a Home fan-out can't trip the CDN/WAF (Sodalite#12/#14). Timeout clock only starts once issued, so a queued waiter never times out. Cancellation-aware: a cancelled waiter throws CancellationError and dequeues so it never strands a permit (else cancelled fan-out tasks leak permits until the pool starves). `nonisolated` (opts out of MainActor): NSLock provides thread-safety for the Sendable cancel handler touching `waiters`.
nonisolated final class AsyncSemaphore: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let isBackground: Bool
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Sodalite#72: the lane a waiter joins, read from the task that is waiting.
    ///
    /// The issue's own objection was that task priority "applies to the Swift task, not to the
    /// position in the semaphore queue". It does now: this is the one place that turns the priority
    /// the caller already carries into a position. Home's precompute passes all run at `.utility`
    /// (`HomeViewModel.swift:448/456/464`, `+Precompute.swift:45/118`) and a tap does not, so no
    /// call site has to be told anything.
    private static func currentIsBackground() -> Bool {
        Task.currentPriority <= .utility
    }

    private let limit: Int
    private var available: Int
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    private let lock = NSLock()

    init(limit: Int) {
        precondition(limit > 0, "AsyncSemaphore needs at least one permit")
        self.limit = limit
        self.available = limit
    }

    /// Acquire a permit (suspends until free; throws CancellationError if cancelled first). Caller must balance with exactly one `signal()`.
    func wait() async throws {
        let id = nextWaiterID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if available > 0 {
                    available -= 1
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(id: id, isBackground: Self.currentIsBackground(),
                                      continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: idx)
                lock.unlock()
                waiter.continuation.resume(throwing: CancellationError())
            } else {
                lock.unlock()
            }
        }
    }

    /// Release a permit, waking the longest-waiting task of the highest lane present.
    ///
    /// Sodalite#72: interactive before background, arrival order within each. Measured on the
    /// documented Home load (14 background requests against 6 permits), a tap used to wait almost
    /// exactly one background request: 64 ms behind a 60 ms hold, 3136 ms behind a 3000 ms one, so
    /// the cost tracked the HOLD rather than the queue depth. The longest hold in the app is a
    /// single `limit: 10000` library scan whose own comment calls its runtime multi-second.
    func signal() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
        } else {
            let index = waiters.firstIndex { !$0.isBackground } ?? 0
            let waiter = waiters.remove(at: index)
            lock.unlock()
            waiter.continuation.resume()
        }
    }

    private func nextWaiterID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }
}
