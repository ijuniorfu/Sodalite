import Testing
import Foundation
@testable import Sodalite

@MainActor
struct PendingRequestsMonitorTests {
    @Test func shouldNotifyOnlyOnIncrease() {
        #expect(PendingRequestsMonitor.shouldNotify(current: 3, lastSeen: 2) == true)
        #expect(PendingRequestsMonitor.shouldNotify(current: 2, lastSeen: 2) == false)
        #expect(PendingRequestsMonitor.shouldNotify(current: 1, lastSeen: 2) == false)
        #expect(PendingRequestsMonitor.shouldNotify(current: 1, lastSeen: 0) == true)
    }

    @Test func refreshIgnoredWhenIneligible() async {
        let monitor = PendingRequestsMonitor()
        monitor.isEligible = { false }
        monitor.fetchPendingCount = { 5 }
        await monitor.refresh()
        #expect(monitor.pendingApprovalCount == nil)
    }

    @Test func refreshStoresCount() async {
        let monitor = PendingRequestsMonitor()
        monitor.isEligible = { true }
        monitor.fetchPendingCount = { 4 }
        await monitor.refresh()
        #expect(monitor.pendingApprovalCount == 4)
    }

    @Test func refreshPreservesPriorValueOnFailure() async {
        struct Boom: Error {}
        let monitor = PendingRequestsMonitor()
        monitor.isEligible = { true }
        monitor.fetchPendingCount = { 6 }
        await monitor.refresh()
        monitor.fetchPendingCount = { throw Boom() }
        await monitor.refresh()
        #expect(monitor.pendingApprovalCount == 6)
    }

    @Test func resetClearsCount() async {
        let monitor = PendingRequestsMonitor()
        monitor.isEligible = { true }
        monitor.fetchPendingCount = { 2 }
        await monitor.refresh()
        monitor.reset()
        #expect(monitor.pendingApprovalCount == nil)
    }
}
