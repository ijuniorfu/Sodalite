import Foundation

/// A FIFO counting semaphore for async/await. Bounds how many
/// operations may proceed concurrently, suspending the rest until a
/// permit frees up.
///
/// `HTTPClient` holds one to cap the number of in-flight requests on
/// its `URLSession`. Without it, a Home fan-out on a multi-library
/// server bursts 60-90 requests in a few seconds (one per per-library
/// Latest row, one per genre, one per streaming provider, plus the
/// background precompute passes), all funnelled through a single
/// connection pool. A CDN/WAF in front of Jellyfin reads that burst as
/// scraping and tarpits the client for ~a minute, while requests
/// queued behind it blow past their 30 s timeout and silently return
/// nil (Sodalite#12 / #14). Admitting at most N at a time keeps the
/// client to browser-like per-host concurrency, and because a
/// request's timeout clock only starts once it is actually issued, a
/// request waiting on a permit never times out while merely queued.
///
/// Cancellation-aware: a task cancelled while waiting for a permit
/// throws `CancellationError` and removes itself from the queue, so it
/// never strands a permit. Without that, the background fan-out tasks
/// (cancelled on every profile switch / re-entrant load) would each
/// leak a permit and permanently shrink the pool until every Jellyfin
/// request hangs forever.
/// `nonisolated` so it opts out of the project's default MainActor
/// isolation: every method runs wherever it is called (including the
/// Sendable cancellation handler that touches `waiters`), with the
/// `NSLock` rather than an actor providing thread-safety.
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

    /// Acquire a permit, suspending until one is free. Throws
    /// `CancellationError` if the awaiting task is cancelled before a
    /// permit is granted. On success the caller owns a permit and must
    /// balance it with exactly one `signal()`.
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
