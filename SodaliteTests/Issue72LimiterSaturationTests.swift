import Foundation
import Testing
@testable import Sodalite

/// Sodalite#72, the measurement the issue asks for before a fix is chosen: "how often the limiter
/// is actually saturated at the moment of a tap".
///
/// This is a MODEL, not a field capture. It drives the real `AsyncSemaphore` at the real limit with
/// the concurrency the Home passes are documented to use (`precomputeProviderCounts` at 4,
/// `precomputeGenreCaches` at 4, `loadProviderBackdrops` at 6), and a per-request hold that stands
/// in for a Jellyfin round trip. What it cannot model is how long those passes actually run against
/// a real server, so it answers "how bad is a tap that lands while they are running", not "how often
/// does a tap land there".
@Suite(.serialized)
struct Issue72LimiterSaturationTests {

    private static let limit = 6
    private static let backgroundConcurrency = 4 + 4 + 6

    /// One permit hold, standing in for a Jellyfin request.
    private func hold(_ limiter: AsyncSemaphore, _ seconds: Double) async throws {
        try await limiter.wait()
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        limiter.signal()
    }

    private func measureTapWait(requestSeconds: Double) async throws -> Double {
        let limiter = AsyncSemaphore(limit: Self.limit)
        // `.utility`, because that is what every Home precompute pass runs at
        // (HomeViewModel.swift:448/456/464, +Precompute.swift:45/118). Without it the model puts
        // the tap in the SAME lane as the passes and measures FIFO rather than the app.
        let background = Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.backgroundConcurrency {
                    group.addTask(priority: .utility) {
                        // Each background worker keeps its lane busy for the whole window.
                        for _ in 0..<6 { try? await self.hold(limiter, requestSeconds) }
                    }
                }
            }
        }
        // Let the passes saturate the limiter before the tap arrives.
        try? await Task.sleep(nanoseconds: UInt64(requestSeconds * 2 * 1_000_000_000))
        let waited = await Task(priority: .userInitiated) { () -> Double in
            let start = DispatchTime.now()
            try? await limiter.wait()
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            limiter.signal()
            return seconds
        }.value
        background.cancel()
        return waited
    }

    /// The sweep is the finding: the tap's wait tracks the HOLD, not the queue depth, because the
    /// depth is fixed by the passes' own concurrency while the hold is whatever the server takes.
    @Test("a tap arriving during the Home passes waits behind them")
    func tapWaitsBehindBackground() async throws {
        for hold in [0.06, 0.25, 1.0, 3.0] {
            let waited = try await measureTapWait(requestSeconds: hold)
            print(String(format:
                "[S72] limit=%d background=%d hold=%5.0f ms -> tap waited %6.0f ms (%.2f x hold)",
                Self.limit, Self.backgroundConcurrency, hold * 1000, waited * 1000, waited / hold))
            #expect(waited < hold, "the tap paid a whole background request: \(waited)s")
        }
    }

    /// The structural fact behind the number, and the one a priority lane would change: the queue is
    /// strictly FIFO, so a tap is served only after every request already waiting.
    @Test("the limiter serves strictly in arrival order, whoever is waiting")
    func servesInArrivalOrder() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.wait()                      // hold the only permit

        let order = OrderRecorder()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<5 {
            tasks.append(Task {
                try? await limiter.wait()
                await order.record(i)
                limiter.signal()
            })
            // Give each waiter time to enqueue, so arrival order is deterministic.
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        limiter.signal()
        for t in tasks { _ = await t.value }
        let seen = await order.values
        #expect(seen == [0, 1, 2, 3, 4], "arrival order is what the queue honours today")
    }

    /// The lane itself. Background waiters queue first and an interactive one arrives last; it must
    /// still be served first, because the passes that hold the permits run at `.utility` and the
    /// tap does not. Within one class arrival order still decides, which `servesInArrivalOrder`
    /// above pins.
    @Test("an interactive waiter overtakes background ones already in the queue")
    func interactiveOvertakesBackground() async throws {
        let limiter = AsyncSemaphore(limit: 1)
        try await limiter.wait()                      // hold the only permit

        let order = OrderRecorder()
        var tasks: [Task<Void, Never>] = []
        for i in 0..<3 {
            tasks.append(Task(priority: .utility) {
                try? await limiter.wait()
                await order.record(i)
                limiter.signal()
            })
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        // Arrives last, at a priority a tap actually carries.
        tasks.append(Task(priority: .userInitiated) {
            try? await limiter.wait()
            await order.record(99)
            limiter.signal()
        })
        try? await Task.sleep(nanoseconds: 60_000_000)

        limiter.signal()
        for t in tasks { _ = await t.value }
        let seen = await order.values
        #expect(seen.first == 99, "the tap waited behind .utility work: \(seen)")
        #expect(seen == [99, 0, 1, 2], "background order must stay FIFO among itself")
    }
}

private actor OrderRecorder {
    private(set) var values: [Int] = []
    func record(_ value: Int) { values.append(value) }
}
