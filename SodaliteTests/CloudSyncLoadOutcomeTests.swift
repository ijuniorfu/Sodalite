import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync manual load outcome")
struct CloudSyncLoadOutcomeTests {

    @Test("servers landing locally reads as loaded regardless of status")
    func loadedWhenServersLanded() {
        #expect(CloudSyncLoadOutcome.resolve(status: .active(lastSyncAt: Date()), hasServers: true) == .loaded)
        #expect(CloudSyncLoadOutcome.resolve(status: .error("late failure"), hasServers: true) == .loaded)
    }

    @Test("an empty zone is only reported when the engine is healthy")
    func emptyOnlyWhenHealthy() {
        #expect(CloudSyncLoadOutcome.resolve(status: .active(lastSyncAt: nil), hasServers: false) == .empty)
        #expect(CloudSyncLoadOutcome.resolve(status: .syncing, hasServers: false) == .empty)
    }

    @Test("a failed fetch is never reported as an empty zone")
    func errorIsNotEmpty() {
        #expect(CloudSyncLoadOutcome.resolve(status: .error("boom"), hasServers: false) == .failed("boom"))
    }

    @Test("sync still disabled after the attempt is a failure, not an empty zone")
    func disabledIsNotEmpty() {
        #expect(CloudSyncLoadOutcome.resolve(status: .disabled, hasServers: false) == .failed(nil))
    }

    @Test("a missing iCloud account keeps its own outcome")
    func noAccountKeepsItsOwnCase() {
        #expect(CloudSyncLoadOutcome.resolve(status: .noAccount, hasServers: false) == .noAccount)
    }
}
