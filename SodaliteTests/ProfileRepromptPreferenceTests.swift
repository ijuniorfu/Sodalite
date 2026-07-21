import Testing
import Foundation
@testable import Sodalite

struct ProfileRepromptPreferenceTests {
    private func freshStore(_ name: String) -> UserDefaults {
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func defaultsToOff() {
        let prefs = AuthPreferences(store: freshStore("reprompt-default"))
        #expect(prefs.profileReprompt == .off)
    }

    @Test func roundTripsThroughStore() {
        let name = "reprompt-roundtrip"
        let store = freshStore(name)
        AuthPreferences(store: store).profileReprompt = .after5min
        #expect(AuthPreferences(store: UserDefaults(suiteName: name)!).profileReprompt == .after5min)
    }

    @Test func unknownRawValueFallsBackToOff() {
        let store = freshStore("reprompt-bogus")
        store.set("bogus", forKey: "auth.profileReprompt")
        #expect(AuthPreferences(store: store).profileReprompt == .off)
    }

    @Test func thresholds() {
        #expect(AuthPreferences.ProfileRepromptInterval.off.threshold == nil)
        #expect(AuthPreferences.ProfileRepromptInterval.immediately.threshold == .zero)
        #expect(AuthPreferences.ProfileRepromptInterval.after30s.threshold == .seconds(30))
        #expect(AuthPreferences.ProfileRepromptInterval.after1min.threshold == .seconds(60))
        #expect(AuthPreferences.ProfileRepromptInterval.after5min.threshold == .seconds(300))
        #expect(AuthPreferences.ProfileRepromptInterval.after15min.threshold == .seconds(900))
        #expect(AuthPreferences.ProfileRepromptInterval.after60min.threshold == .seconds(3600))
    }
}
