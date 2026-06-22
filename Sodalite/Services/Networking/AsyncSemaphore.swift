import Foundation

/// FIFO counting semaphore for async/await; caps HTTPClient in-flight requests so a Home fan-out can't trip the CDN/WAF (Sodalite#12/#14). Timeout clock only starts once issued, so a queued waiter never times out. Cancellation-aware: a cancelled waiter throws CancellationError and dequeues so it never strands a permit (else cancelled fan-out tasks leak permits until the pool starves). `nonisolated` (opts out of MainActor): NSLock provides thread-safety for the Sendable cancel handler touching `waiters`.
nonisolated final class AsyncSemaphore: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, Error>
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
                waiters.append(Waiter(id: id, continuation: continuation))
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

    /// Release a permit, waking the longest-waiting task if any.
    func signal() {
        lock.lock()
        if waiters.isEmpty {
            available += 1
            lock.unlock()
        } else {
            let waiter = waiters.removeFirst()
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
