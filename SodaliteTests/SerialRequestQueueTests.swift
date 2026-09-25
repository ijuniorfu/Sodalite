import Testing
import Foundation
@testable import Sodalite

/// The chapter menu mounts several rows at once and the frame extractor supersedes its in-flight
/// decode on every new request, so only the last row ever got a still. The queue has them take
/// turns. Audit 2026-09-25 PLAYER-PERIPHERY-1.
@MainActor
struct SerialRequestQueueTests {

    @MainActor final class Log {
        var events: [String] = []
        var running = 0
        var maxRunning = 0
    }

    private func request(_ name: String, log: Log) -> @MainActor () async -> String? {
        {
            log.running += 1
            log.maxRunning = max(log.maxRunning, log.running)
            log.events.append("start \(name)")
            try? await Task.sleep(for: .milliseconds(20))
            log.events.append("end \(name)")
            log.running -= 1
            return name
        }
    }

    @Test func requestsThatArriveTogetherRunOneAtATimeInArrivalOrder() async {
        let queue = SerialRequestQueue()
        let log = Log()
        // Enqueued in a known order (one row after another, the way a lazy list mounts them),
        // none awaited before the last one is in.
        var tasks: [Task<String?, Never>] = []
        for name in ["a", "b", "c"] {
            tasks.append(Task { await queue.run(request(name, log: log)) })
            await Task.yield()
        }
        var results: [String?] = []
        for task in tasks { results.append(await task.value) }

        #expect(results == ["a", "b", "c"])
        #expect(log.maxRunning == 1)
        #expect(log.events == ["start a", "end a", "start b", "end b", "start c", "end c"])
    }

    /// A row scrolled away before its turn must not decode for nobody.
    @Test func aRequestCancelledWhileWaitingNeverRuns() async {
        let queue = SerialRequestQueue()
        let log = Log()
        let first = Task { await queue.run(request("first", log: log)) }
        await Task.yield()
        let dropped = Task { await queue.run(request("dropped", log: log)) }
        await Task.yield()
        dropped.cancel()
        let last = Task { await queue.run(request("last", log: log)) }

        #expect(await first.value == "first")
        #expect(await dropped.value == nil)
        #expect(await last.value == "last")
        #expect(!log.events.contains("start dropped"))
    }
}
