import Testing
import Foundation
@testable import Sodalite

@MainActor
struct SeerrNotificationPreferencesTests {
    private func isolatedDefaults() -> UserDefaults {
        let suite = "test.seerrNotif.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test func defaultsAreOff() {
        let prefs = SeerrNotificationPreferences(defaults: isolatedDefaults())
        #expect(prefs.notifyPendingRequests == false)
        #expect(prefs.lastSeenPendingCount == 0)
    }

    @Test func persistsAcrossInstances() {
        let defaults = isolatedDefaults()
        let a = SeerrNotificationPreferences(defaults: defaults)
        a.notifyPendingRequests = true
        a.lastSeenPendingCount = 7
        let b = SeerrNotificationPreferences(defaults: defaults)
        #expect(b.notifyPendingRequests == true)
        #expect(b.lastSeenPendingCount == 7)
    }
}
