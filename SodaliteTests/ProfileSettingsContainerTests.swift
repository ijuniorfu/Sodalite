import Foundation
import Testing
@testable import Sodalite

@Suite("Per-profile settings in the container", .serialized)
@MainActor
struct ProfileSettingsContainerTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profileContainer.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Held by the suite instance: `DependencyContainer.appState` is weak, and a state that only lives
    /// in a discarded tuple element is gone before the first read, which silently leaves no profile active.
    private let state = AppState()

    private func signedIn(_ defaults: UserDefaults, as userID: String, server: String) throws -> DependencyContainer {
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults)
        container.appState = state
        let jellyfin = JellyfinServer(id: server, name: "Main", url: URL(string: "https://jf.example")!, version: "10.10")
        try container.addServer(jellyfin)
        state.setAuthenticated(
            server: jellyfin,
            user: JellyfinUser(id: userID, name: userID, serverID: server, hasPassword: true, primaryImageTag: nil, policy: nil)
        )
        #expect(container.activeProfileKey == ProfileKey(serverID: server, userID: userID))
        return container
    }

    @Test func aLegacyRecordNeverReachesTheActiveProfile() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("legacyApply"), as: "alice", server: server)
        container.appearancePreferences.largeCards = false
        guard case .appearance(var payload) = container.collectSettingsPayload(.appearance, stamp: .now) else {
            Issue.record("wrong case"); return
        }
        payload.largeCards = true
        payload.showTopShelfRow = false

        container.applySettingsPayload(.appearance(payload))

        #expect(container.appearancePreferences.largeCards == false)
        #expect(container.profileSettings.legacy.appearance.largeCards == true)
        #expect(container.devicePreferences.showTopShelfRow == false)
    }

    @Test func theLegacyRecordMirrorsTheProfileItWasCapturedFor() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("mirror"), as: "alice", server: server)
        let bob = ProfileKey(serverID: server, userID: "bob")
        container.playbackPreferences.subtitleFontSize = .xlarge
        container.profileSettings.settings(for: bob).playback.subtitleFontSize = .small

        guard case .playback(let active) = container.collectSettingsPayload(.playback, stamp: .now),
              case .playback(let captured) = container.collectSettingsPayload(.playback, stamp: .now, profile: bob)
        else { Issue.record("wrong case"); return }

        #expect(active.subtitleFontSize == "xlarge")
        #expect(captured.subtitleFontSize == "small")
    }

    @Test func aProfileRecordIsAppliedWithoutCountingAsAnEdit() throws {
        let server = "c-\(UUID().uuidString)"
        let container = try signedIn(scratch("profileApply"), as: "alice", server: server)
        let bob = ProfileKey(serverID: server, userID: "bob")
        var edits = 0
        container.profileSettings.onLocalEdit = { _, _ in edits += 1 }
        let source = AppearancePreferences(store: scratch("profileApplySource"))
        source.accentChoice = .gold

        container.applyProfilePayload(.appearance(ProfileAppearancePayload(collecting: source, stamp: .now)), key: bob)

        #expect(edits == 0)
        #expect(container.profileSettings.settings(for: bob).appearance.accentChoice == .gold)
        #expect(!container.profileSettings.isProvisional(bob, .appearance))
        #expect(container.profileSettings.isProvisional(bob, .playback))
    }

    @Test func aProfileWithoutValuesHasNothingToCollect() throws {
        let container = try signedIn(scratch("collectNil"), as: "alice", server: "c-\(UUID().uuidString)")
        #expect(container.collectProfilePayload(.playback, key: ProfileKey(serverID: "x", userID: "nobody"), stamp: .now) == nil)
    }

    @Test func theServerRecordMirrorsTheHomeRowsOfTheProfileLastSignedInThere() throws {
        let server = "c-\(UUID().uuidString)"
        let keychain = InMemoryKeychain()
        let container = DependencyContainer(keychainService: keychain, defaults: scratch("serverHome"))
        try container.addServer(JellyfinServer(id: server, name: "Main", url: URL(string: "https://jf.example")!, version: "10.10"))
        try keychain.save("alice", for: KeychainKeys.userID(serverID: server))
        let alice = ProfileKey(serverID: server, userID: "alice")
        _ = container.profileSettings.settings(for: alice)
        HomeRowConfig.setMergeContinueWatchingNextUp(true, scope: alice.storageScope)
        HomeRowConfig.setMergeContinueWatchingNextUp(false, scope: server)

        let payload = try #require(container.collectServerPayload(serverID: server, stamp: .now))

        #expect(payload.homeRows?.mergeCWNextUp == true)
    }

    @Test func launchMigratesEveryRememberedProfile() throws {
        let server = "c-\(UUID().uuidString)"
        let keychain = InMemoryKeychain()
        let setup = DependencyContainer(keychainService: keychain, defaults: scratch("launchSetup"))
        try setup.addServer(JellyfinServer(id: server, name: "Main", url: URL(string: "https://jf.example")!, version: "10.10"))
        try setup.rememberUser(RememberedUser(id: "alice", serverID: server, name: "alice", imageTag: nil, token: "t1"))
        try setup.rememberUser(RememberedUser(id: "bob", serverID: server, name: "bob", imageTag: nil, token: "t2"))
        let defaults = scratch("launch")
        PlaybackPreferences(store: defaults).autoSkipRecap = true

        let launched = DependencyContainer(keychainService: keychain, defaults: defaults)

        for user in ["alice", "bob"] {
            let key = ProfileKey(serverID: server, userID: user)
            #expect(launched.profileSettings.hasValues(key))
            #expect(launched.profileSettings.settings(for: key).playback.autoSkipRecap)
        }
    }
}
