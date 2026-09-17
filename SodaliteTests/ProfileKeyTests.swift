import Foundation
import Testing
@testable import Sodalite

@Suite("Profile key and keyspace", .serialized)
@MainActor
struct ProfileKeyTests {
    @Test func storageScopeMatchesTheParentalControlsFormat() {
        let key = ProfileKey(serverID: "s1", userID: "u1")
        #expect(key.storageScope == ProfileRef(serverID: "s1", userID: "u1").compositeID)
        #expect(key.storageScope == "s1:u1")
    }

    @Test func storageScopeRoundTrips() {
        let key = ProfileKey(serverID: "0f3a9c", userID: "4b8e-77")
        #expect(ProfileKey(storageScope: key.storageScope) == key)
    }

    @Test func malformedScopesAreRejected() {
        #expect(ProfileKey(storageScope: "") == nil)
        #expect(ProfileKey(storageScope: "s1") == nil)
        #expect(ProfileKey(storageScope: ":u1") == nil)
        #expect(ProfileKey(storageScope: "s1:") == nil)
    }

    @Test func aScopedKeyspacePrefixesAndAnUnscopedOneDoesNot() {
        let suite = "keyspace.prefix"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let scoped = PreferenceKeyspace(defaults: defaults, scope: "s1:u1")
        let legacy = PreferenceKeyspace(defaults: defaults, scope: nil)

        scoped.set(true, forKey: "playback.autoSkipIntro")

        #expect(defaults.object(forKey: "s1:u1/playback.autoSkipIntro") as? Bool == true)
        #expect(defaults.object(forKey: "playback.autoSkipIntro") == nil)
        #expect(legacy.object(forKey: "playback.autoSkipIntro") == nil)
        #expect(scoped.object(forKey: "playback.autoSkipIntro") as? Bool == true)
    }

    @Test func everyWriteIsReportedWithItsUnprefixedName() {
        let suite = "keyspace.onWrite"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let space = PreferenceKeyspace(defaults: defaults, scope: "s1:u1")
        var written: [String] = []
        space.onWrite = { written.append($0) }

        space.set("ger", forKey: "playback.preferredAudioLanguage")
        space.set(nil, forKey: "playback.preferredAudioLanguage")

        #expect(written == ["playback.preferredAudioLanguage", "playback.preferredAudioLanguage"])
        #expect(space.string(forKey: "playback.preferredAudioLanguage") == nil)
    }
}
