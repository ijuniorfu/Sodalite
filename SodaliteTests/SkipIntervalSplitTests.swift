import Foundation
import Testing
@testable import Sodalite

/// Sodalite#144: forward and back became two settings. The thing that must not happen is an install
/// waking up with jumps it never asked for, so the split is pinned from three sides: what an upgrade
/// reads, what a direction resolves to, and what crosses CloudSync to and from a build that still
/// has one interval.
@Suite("Split skip intervals (Sodalite#144)", .serialized)
@MainActor
struct SkipIntervalSplitTests {

    private func emptySuite(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "skipSplit.\(name)")!
        suite.removePersistentDomain(forName: "skipSplit.\(name)")
        return suite
    }

    // MARK: - Upgrade

    @Test("an install that had 30 s keeps 30 s in both directions")
    func theLegacyIntervalSeedsBothDirections() {
        let suite = emptySuite("legacy")
        suite.set(30, forKey: "playback.skipIntervalSeconds")

        let prefs = PlaybackPreferences(store: suite)

        #expect(prefs.skipForwardSeconds == 30)
        #expect(prefs.skipBackwardSeconds == 30)
    }

    @Test("a fresh install jumps 10 s either way, as it always did")
    func aVirginStoreKeepsTheShippedDefault() {
        let prefs = PlaybackPreferences(store: emptySuite("virgin"))
        #expect(prefs.skipForwardSeconds == 10)
        #expect(prefs.skipBackwardSeconds == 10)
    }

    @Test("once the directions are set apart the legacy key stops speaking for them")
    func anExplicitValueOutranksTheLegacyKey() {
        let suite = emptySuite("explicit")
        suite.set(30, forKey: "playback.skipIntervalSeconds")
        suite.set(15, forKey: "playback.skipForwardSeconds")
        suite.set(5, forKey: "playback.skipBackwardSeconds")

        let prefs = PlaybackPreferences(store: suite)

        #expect(prefs.skipForwardSeconds == 15)
        #expect(prefs.skipBackwardSeconds == 5)
    }

    /// A downgrade has to land on the value the old build last knew, not on a default, so setting the
    /// new keys must leave the old one alone.
    @Test("setting a direction does not overwrite the pre-split key")
    func theLegacyKeySurvivesAWrite() {
        let suite = emptySuite("downgrade")
        suite.set(30, forKey: "playback.skipIntervalSeconds")

        let prefs = PlaybackPreferences(store: suite)
        prefs.skipForwardSeconds = 15
        prefs.skipBackwardSeconds = 5

        #expect(suite.object(forKey: "playback.skipIntervalSeconds") as? Int == 30)
    }

    // MARK: - Direction

    @Test("the direction, not the caller, decides which of the two is read")
    func theLookupAnswersPerDirection() {
        let prefs = PlaybackPreferences(store: emptySuite("direction"))
        prefs.skipForwardSeconds = 30
        prefs.skipBackwardSeconds = 5

        #expect(prefs.skipSeconds(direction: 1) == 30)
        #expect(prefs.skipSeconds(direction: -1) == 5)
        // The two transports pass the raw move command, which is +1/-1, but nothing promises that.
        #expect(prefs.skipSeconds(direction: 4) == 30)
        #expect(prefs.skipSeconds(direction: -4) == 5)
        #expect(prefs.skipSeconds(direction: 0) == 30)
    }

    @Test("every offered interval is offered in both directions")
    func bothRowsOfferTheSameChoices() {
        #expect(PlaybackPreferences.skipIntervalChoices == [5, 10, 15, 30])
    }

    // MARK: - CloudSync

    /// The container's own stores are what `collectSettingsPayload` reads, so the test drives those
    /// and puts them back afterwards. `SettingsStores` cannot be assembled from outside.
    private func playbackPayload(of container: DependencyContainer) -> PlaybackSettingsPayload {
        guard case .playback(let payload) = container.collectSettingsPayload(
            .playback, stamp: .distantPast
        ) else {
            Issue.record("collect returned the wrong payload case")
            fatalError("unreachable")
        }
        return payload
    }

    @Test("both directions travel, and the pre-split field still carries the forward one")
    func thePayloadCarriesBothAndTheOldField() {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        let store = container.playbackPreferences
        let original = (store.skipForwardSeconds, store.skipBackwardSeconds)
        defer { (store.skipForwardSeconds, store.skipBackwardSeconds) = original }
        store.skipForwardSeconds = 30
        store.skipBackwardSeconds = 5

        let payload = playbackPayload(of: container)

        #expect(payload.skipForwardSeconds == 30)
        #expect(payload.skipBackwardSeconds == 5)
        // What a build without the two fields above reads. Forward, because that is the jump the one
        // row it draws is labelled and iconed for.
        #expect(payload.skipIntervalSeconds == 30)
    }

    /// A payload without the two fields is not silence, unlike every other late addition to this
    /// payload: the sender is stating that both of its jumps are `skipIntervalSeconds` long. So it
    /// applies to both rather than leaving the local values alone.
    @Test("a payload from a build with one interval sets both directions to it")
    func anOlderPayloadSpeaksForBothDirections() {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        let store = container.playbackPreferences
        let original = (store.skipForwardSeconds, store.skipBackwardSeconds)
        defer { (store.skipForwardSeconds, store.skipBackwardSeconds) = original }
        store.skipForwardSeconds = 15
        store.skipBackwardSeconds = 5

        var payload = playbackPayload(of: container)
        payload.skipIntervalSeconds = 30
        payload.skipForwardSeconds = nil
        payload.skipBackwardSeconds = nil
        container.applySettingsPayload(.playback(payload))

        #expect(store.skipForwardSeconds == 30)
        #expect(store.skipBackwardSeconds == 30)
    }

    @Test("a payload that names both directions wins over the pre-split field")
    func anewerPayloadKeepsTheDirectionsApart() {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        let store = container.playbackPreferences
        let original = (store.skipForwardSeconds, store.skipBackwardSeconds)
        defer { (store.skipForwardSeconds, store.skipBackwardSeconds) = original }

        var payload = playbackPayload(of: container)
        payload.skipIntervalSeconds = 30
        payload.skipForwardSeconds = 30
        payload.skipBackwardSeconds = 5
        container.applySettingsPayload(.playback(payload))

        #expect(store.skipForwardSeconds == 30)
        #expect(store.skipBackwardSeconds == 5)
    }
}
