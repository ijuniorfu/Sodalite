import Testing
import Foundation
@testable import Sodalite

/// Sodalite#63. Default ON: the reporter's complaint is that the behaviour is unfindable, and an
/// opt-in nobody discovers does not fix that.
struct SubtitlesOnSkipBackPreferenceTests {

    private func defaults(_ name: String) -> UserDefaults {
        let suite = "SubtitlesOnSkipBackPreferenceTests.\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    @Test func defaultsToOn() {
        #expect(PlaybackPreferences(store: defaults(#function)).subtitlesOnSkipBack)
    }

    @Test func persistsAcrossInstances() {
        let store = defaults(#function)
        let a = PlaybackPreferences(store: store)
        a.subtitlesOnSkipBack = false
        let b = PlaybackPreferences(store: store)
        #expect(!b.subtitlesOnSkipBack)
    }
}
