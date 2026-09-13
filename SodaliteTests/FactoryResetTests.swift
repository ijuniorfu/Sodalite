import Foundation
import Testing
@testable import Sodalite

/// A reset has to write what a FIRST launch holds, and the stores that answer that question are the
/// same ones the app is currently using. Reading them would reset a device to the values it already
/// has. So the factory set is parsed from an empty suite, and the values travel through the very
/// payload mapping CloudSync already pins every setting to (Sodalite#76).
@Suite("Factory defaults for a reset", .serialized)
@MainActor
struct FactoryResetTests {
    private func emptySuite(_ name: String) -> UserDefaults {
        let suite = UserDefaults(suiteName: "factoryReset.\(name)")!
        suite.removePersistentDomain(forName: "factoryReset.\(name)")
        return suite
    }

    @Test func theFactorySetIgnoresWhatThisDeviceHasStored() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        let live = container.playbackPreferences
        let original = live.skipForwardSeconds
        defer { live.skipForwardSeconds = original }
        let virgin = PlaybackPreferences(store: emptySuite("ignores")).skipForwardSeconds
        live.skipForwardSeconds = virgin == 30 ? 45 : 30

        let factory = try #require(SettingsStores.factoryDefaults())
        guard case .playback(let payload) = container.collectSettingsPayload(
            .playback, stamp: .distantPast, from: factory
        ) else {
            Issue.record("collect returned the wrong payload case")
            return
        }

        #expect(payload.skipForwardSeconds == virgin)
        #expect(payload.skipForwardSeconds != live.skipForwardSeconds)
        // The pre-split field an older build still reads carries the same factory value.
        #expect(payload.skipIntervalSeconds == virgin)
    }

    /// The scratch suite is a real, persisted domain: leaving a previous reset's writes (or the
    /// migrations these inits run) in it would make the second reset less of a reset than the first.
    @Test func aSecondResetIsNotInheritedFromTheFirst() throws {
        let first = try #require(SettingsStores.factoryDefaults())
        let virgin = first.playback.skipForwardSeconds
        first.playback.skipForwardSeconds = virgin == 30 ? 45 : 30
        first.appearance.largeCards = !first.appearance.largeCards

        let second = try #require(SettingsStores.factoryDefaults())

        #expect(second.playback.skipForwardSeconds == virgin)
        #expect(second.appearance.largeCards == AppearancePreferences(store: emptySuite("second")).largeCards)
    }

    /// Every synced store, not a hand-kept subset: a store missing here is a preference that would
    /// survive a reset, and nothing about the screen afterwards would say so.
    @Test func everySyncedStoreHasAFactoryPayload() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        let factory = try #require(SettingsStores.factoryDefaults())

        for key in CloudSyncStoreKey.allCases {
            let payload = container.collectSettingsPayload(key, stamp: .distantPast, from: factory)
            #expect(payload.storeKey == key)
        }
    }
}
