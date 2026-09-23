import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync manual load outcome")
struct CloudSyncLoadOutcomeTests {

    @Test("servers landing locally reads as loaded regardless of status")
    func loadedWhenServersLanded() {
        #expect(CloudSyncLoadOutcome.resolve(status: .active(lastSyncAt: Date()), hasServers: true, adoptionCompleted: true) == .loaded)
        #expect(CloudSyncLoadOutcome.resolve(status: .error("late failure"), hasServers: true, adoptionCompleted: true) == .loaded)
    }

    @Test("an empty zone is only reported when the engine is healthy")
    func emptyOnlyWhenHealthy() {
        #expect(CloudSyncLoadOutcome.resolve(status: .active(lastSyncAt: nil), hasServers: false, adoptionCompleted: true) == .empty)
        #expect(CloudSyncLoadOutcome.resolve(status: .syncing, hasServers: false, adoptionCompleted: true) == .empty)
    }

    /// The engine reports healthy before its adoption fetch has run, and a tap in that window read
    /// an unfetched zone as an empty one ("no data found" on a new phone, then the data arrived).
    @Test("a zone this device has not adopted yet is never reported empty")
    func unadoptedIsNotEmpty() {
        #expect(CloudSyncLoadOutcome.resolve(status: .active(lastSyncAt: nil), hasServers: false, adoptionCompleted: false) == .failed(nil))
        #expect(CloudSyncLoadOutcome.resolve(status: .syncing, hasServers: false, adoptionCompleted: false) == .failed(nil))
        #expect(CloudSyncLoadOutcome.resolve(status: .syncing, hasServers: true, adoptionCompleted: false) == .loaded)
    }

    @Test("a failed fetch is never reported as an empty zone")
    func errorIsNotEmpty() {
        #expect(CloudSyncLoadOutcome.resolve(status: .error("boom"), hasServers: false, adoptionCompleted: true) == .failed("boom"))
    }

    @Test("sync still disabled after the attempt is a failure, not an empty zone")
    func disabledIsNotEmpty() {
        #expect(CloudSyncLoadOutcome.resolve(status: .disabled, hasServers: false, adoptionCompleted: true) == .failed(nil))
    }

    @Test("a missing iCloud account keeps its own outcome")
    func noAccountKeepsItsOwnCase() {
        #expect(CloudSyncLoadOutcome.resolve(status: .noAccount, hasServers: false, adoptionCompleted: true) == .noAccount)
    }
}
