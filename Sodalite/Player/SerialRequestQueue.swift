import Foundation

/// Runs async requests one at a time, in arrival order, and drops a request whose caller gave up
/// while it was still waiting.
///
/// For a consumer that supersedes rather than queues: `FrameExtractor` cancels its in-flight decode
/// whenever a new one arrives, which is right for a scrub and wrong for a list of chapter rows that
/// all ask at once (only the last row ever got a still). Rows mount in reading order, so FIFO is
/// visible-first, and a row scrolled away before its turn costs nothing.
@MainActor
final class SerialRequestQueue {
    private var tail: Task<Void, Never>?

    nonisolated init() {}

    func run<T: Sendable>(_ work: @escaping @MainActor () async -> T?) async -> T? {
        let previous = tail
        let job = Task { @MainActor () -> T? in
            await previous?.value
            guard !Task.isCancelled else { return nil }
            return await work()
        }
        tail = Task { _ = await job.value }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }
}
