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
        #expect(prefs.lastSeenPendingCount(jellyfinServerID: "S", jellyfinUserID: "U") == 0)
    }

    @Test func persistsAcrossInstances() {
        let defaults = isolatedDefaults()
        let a = SeerrNotificationPreferences(defaults: defaults)
        a.notifyPendingRequests = true
        a.setLastSeenPendingCount(7, jellyfinServerID: "S", jellyfinUserID: "U")
        let b = SeerrNotificationPreferences(defaults: defaults)
        #expect(b.notifyPendingRequests == true)
        #expect(b.lastSeenPendingCount(jellyfinServerID: "S", jellyfinUserID: "U") == 7)
    }

    // Each Jellyfin profile has its own Seerr session, so one profile's baseline must never
    // silence (or trigger) another profile's notification.
    @Test func baselineIsPerProfile() {
        let prefs = SeerrNotificationPreferences(defaults: isolatedDefaults())
        prefs.setLastSeenPendingCount(7, jellyfinServerID: "S", jellyfinUserID: "U")
        #expect(prefs.lastSeenPendingCount(jellyfinServerID: "S", jellyfinUserID: "OTHER") == 0)
        #expect(prefs.lastSeenPendingCount(jellyfinServerID: "OTHER", jellyfinUserID: "U") == 0)
        #expect(prefs.lastSeenPendingCount(jellyfinServerID: "S", jellyfinUserID: "U") == 7)
    }

    // The retired device-global baseline is dropped rather than guessed onto a profile.
    @Test func legacyGlobalBaselineIsRetired() {
        let defaults = isolatedDefaults()
        defaults.set(12, forKey: "seerr.lastSeenPendingCount")
        let prefs = SeerrNotificationPreferences(defaults: defaults)
        #expect(defaults.object(forKey: "seerr.lastSeenPendingCount") == nil)
        #expect(prefs.lastSeenPendingCount(jellyfinServerID: "S", jellyfinUserID: "U") == 0)
    }
}
