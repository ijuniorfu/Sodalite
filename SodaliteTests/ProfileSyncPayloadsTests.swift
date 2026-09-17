import Foundation
import Testing
@testable import Sodalite

@Suite("Profile sync payloads", .serialized)
@MainActor
struct ProfileSyncPayloadsTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profilePayloads.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func storedSettingNames(of store: Any) -> Set<String> {
        Set(
            Mirror(reflecting: store).children
                .compactMap(\.label)
                .filter { $0.hasPrefix("_") && $0 != "_$observationRegistrar" }
                .map { String($0.dropFirst()) }
        )
    }

    private func fields(_ payload: Any) -> Set<String> {
        CloudSyncForwardCompat.storedPropertyNames(of: payload).subtracting(["schemaVersion", "updatedAt"])
    }

    @Test func everyProfilePlaybackSettingIsInItsPayload() {
        let store = PlaybackPreferences(store: scratch("pb"))
        #expect(storedSettingNames(of: store) == fields(ProfilePlaybackPayload(collecting: store, stamp: .distantPast)))
    }

    @Test func everyProfileAppearanceSettingIsInItsPayload() {
        let store = AppearancePreferences(store: scratch("ap"))
        #expect(storedSettingNames(of: store) == fields(ProfileAppearancePayload(collecting: store, stamp: .distantPast)))
    }

    @Test func aProfilePayloadRoundTripsIntoAnotherProfile() throws {
        let defaults = scratch("roundTrip")
        let device = DevicePreferences(store: defaults)
        let source = PlaybackPreferences(store: defaults, scope: "s:a", device: device)
        source.preferredAudioLanguage = "ger"
        source.subtitleBackground = .outline
        source.nextEpisodeCountdownAnchor = .end
        let look = AppearancePreferences(store: defaults, scope: "s:a", device: device)
        look.hiddenTabs = [.catalog]
        look.navigationStyle = .sidebar

        let data = try ProfileSyncPayload.playback(ProfilePlaybackPayload(collecting: source, stamp: .now)).encoded()
        let lookData = try ProfileSyncPayload.appearance(ProfileAppearancePayload(collecting: look, stamp: .now)).encoded()
        let target = PlaybackPreferences(store: defaults, scope: "s:b", device: device)
        let targetLook = AppearancePreferences(store: defaults, scope: "s:b", device: device)
        guard case .playback(let decoded) = try ProfileSyncPayload.decode(data, kind: .playback),
              case .appearance(let decodedLook) = try ProfileSyncPayload.decode(lookData, kind: .appearance)
        else { Issue.record("wrong case"); return }
        decoded.apply(to: target)
        decodedLook.apply(to: targetLook)

        #expect(target.preferredAudioLanguage == "ger")
        #expect(target.subtitleBackground == .outline)
        #expect(target.nextEpisodeCountdownAnchor == .end)
        #expect(targetLook.hiddenTabs == [.catalog])
        #expect(targetLook.navigationStyle == .sidebar)
    }

    @Test func anUnknownRawValueKeepsTheCurrentValue() {
        let store = PlaybackPreferences(store: scratch("unknown"))
        store.subtitleColor = .yellow
        var payload = ProfilePlaybackPayload(collecting: store, stamp: .now)
        payload.subtitleColor = "ultraviolet"

        payload.apply(to: store)

        #expect(store.subtitleColor == .yellow)
    }

    @Test func onlyPlaybackAndAppearanceAreProfileBacked() {
        #expect(CloudSyncStoreKey.allCases.filter(\.isProfileBacked) == [.playback, .appearance])
        #expect(ProfileRecordKind.playback.legacyStoreKey == .playback)
        #expect(ProfileRecordKind.appearance.legacyStoreKey == .appearance)
        #expect(ProfileRecordKind.home.legacyStoreKey == nil)
    }
}
