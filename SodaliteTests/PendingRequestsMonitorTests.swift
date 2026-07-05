import Testing
import Foundation
@testable import Sodalite

@MainActor
struct PendingRequestsMonitorTests {
    private func makeMonitor() -> (PendingRequestsMonitor, SeerrNotificationPreferences) {
        let suite = "test.monitor.\(UUID().uuidString)"
        let prefs = SeerrNotificationPreferences(defaults: UserDefaults(suiteName: suite)!)
        return (PendingRequestsMonitor(preferences: prefs), prefs)
    }

    @Test func shouldNotifyOnlyOnIncrease() {
        #expect(PendingRequestsMonitor.shouldNotify(current: 3, lastSeen: 2) == true)
        #expect(PendingRequestsMonitor.shouldNotify(current: 2, lastSeen: 2) == false)
        #expect(PendingRequestsMonitor.shouldNotify(current: 1, lastSeen: 2) == false)
        #expect(PendingRequestsMonitor.shouldNotify(current: 1, lastSeen: 0) == true)
    }

    @Test func refreshIgnoredWhenIneligible() async {
        let (monitor, _) = makeMonitor()
        monitor.isEligible = { false }
        monitor.fetchPendingCount = { 5 }
        await monitor.refresh()
        #expect(monitor.pendingApprovalCount == nil)
    }

    @Test func refreshStoresCountAndBaseline() async {
        let (monitor, prefs) = makeMonitor()
        monitor.isEligible = { true }
        monitor.fetchPendingCount = { 4 }
        await monitor.refresh()
        #expect(monitor.pendingApprovalCount == 4)
        #expect(prefs.lastSeenPendingCount == 4)
    }

    @Test func refreshPreservesPriorValueOnFailure() async {
        struct Boom: Error {}
        let (monitor, _) = makeMonitor()
        monitor.isEligible = { true }
        monitor.fetchPendingCount = { 6 }
        await monitor.refresh()
        monitor.fetchPendingCount = { throw Boom() }
        await monitor.refresh()
        #expect(monitor.pendingApprovalCount == 6)
    }

    @Test func resetClearsCount() async {
        let (monitor, _) = makeMonitor()
        monitor.isEligible = { true }
        monitor.fetchPendingCount = { 2 }
        await monitor.refresh()
        monitor.reset()
        #expect(monitor.pendingApprovalCount == nil)
    }
}
