import Foundation
import Testing
@testable import Sodalite

/// The status row used to be settled back to "Active, last synced …" by the next fetch, which
/// succeeds even against a zone this device has never managed to write to. Three devices therefore
/// reported a recent sync for two weeks while every single upload was being rejected.
@Suite("CloudSync status latch")
struct CloudSyncStatusLatchTests {

    @Test("without a latched failure the candidate passes through untouched")
    func passesThroughWhenHealthy() {
        let latch = CloudSyncStatusLatch()
        let synced = Date(timeIntervalSince1970: 1_000)
        #expect(latch.resolve(.active(lastSyncAt: synced)) == .active(lastSyncAt: synced))
        #expect(latch.resolve(.syncing) == .syncing)
        #expect(latch.resolve(.disabled) == .disabled)
    }

    @Test("a latched failure outlives a fetch that reports health")
    func latchedFailureSurvivesActive() {
        var latch = CloudSyncStatusLatch()
        latch.latch("rejected")
        #expect(latch.resolve(.active(lastSyncAt: Date())) == .error("rejected"))
        #expect(latch.resolve(.active(lastSyncAt: nil)) == .error("rejected"))
    }

    /// Only the upload path can clear it, so an in-flight push still reads as in-flight and a
    /// missing account still reads as a missing account.
    @Test("a latched failure does not overwrite the other states")
    func latchDoesNotMaskOtherStates() {
        var latch = CloudSyncStatusLatch()
        latch.latch("rejected")
        #expect(latch.resolve(.syncing) == .syncing)
        #expect(latch.resolve(.noAccount) == .noAccount)
        #expect(latch.resolve(.disabled) == .disabled)
        #expect(latch.resolve(.error("newer")) == .error("newer"))
    }

    @Test("a save that lands clears the latch")
    func clearingRestoresActive() {
        var latch = CloudSyncStatusLatch()
        latch.latch("rejected")
        latch.clear()
        #expect(latch.resolve(.active(lastSyncAt: nil)) == .active(lastSyncAt: nil))
    }

    @Test("the newest failure is the one shown")
    func latestFailureWins() {
        var latch = CloudSyncStatusLatch()
        latch.latch("first")
        latch.latch("second")
        #expect(latch.resolve(.active(lastSyncAt: nil)) == .error("second"))
    }
}
