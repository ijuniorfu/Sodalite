import Foundation
import Testing
@testable import Sodalite

@Suite("Per-profile settings registry", .serialized)
@MainActor
struct ProfileSettingsRegistryTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profileRegistry.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Fresh server ids per test: home values live in UserDefaults.standard.
    private func profiles() -> (ProfileKey, ProfileKey, ProfileKey) {
        let server = "reg-\(UUID().uuidString)"
        return (ProfileKey(serverID: server, userID: "alice"),
                ProfileKey(serverID: server, userID: "bob"),
                ProfileKey(serverID: server, userID: "carol"))
    }

    @Test func migrationSeedsEveryProfileFromTheDeviceValues() {
        let defaults = scratch("migration")
        let (alice, bob, _) = profiles()
        PlaybackPreferences(store: defaults).subtitleFontSize = .xlarge
        AppearancePreferences(store: defaults).largeCards = true

        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice, bob])

        #expect(registry.settings(for: alice).playback.subtitleFontSize == .xlarge)
        #expect(registry.settings(for: bob).appearance.largeCards)
        #expect(ProfileRecordKind.allCases.allSatisfy { registry.isProvisional(alice, $0) })
        #expect(defaults.string(forKey: "\(alice.storageScope)/playback.subtitleFontSize") == "xlarge")
    }

    @Test func migrationRunsOnceAndLaterProfilesCopyTheLastActiveOne() {
        let defaults = scratch("once")
        let (alice, _, carol) = profiles()
        let first = ProfileSettingsRegistry(defaults: defaults)
        first.migrateIfNeeded(profiles: [alice])
        first.activeKey = { alice }
        first.current.playback.subtitleColor = .yellow

        PlaybackPreferences(store: defaults).subtitleColor = .gray
        let relaunch = ProfileSettingsRegistry(defaults: defaults)
        relaunch.migrateIfNeeded(profiles: [alice, carol])

        #expect(!relaunch.hasValues(carol))
        #expect(relaunch.settings(for: carol).playback.subtitleColor == .yellow)
        #expect(relaunch.settings(for: alice).playback.subtitleColor == .yellow)
    }

    /// The copy has to survive the path the app actually takes. Every screen reads `current`, which
    /// writes `lastActiveKey` on its way to resolving, and the seeding rule reads that same value to
    /// find the profile to copy from. Asking through `settings(for:)` never exercises that order.
    @Test func aNewProfileReachedThroughCurrentCopiesTheLastActiveOne() {
        let defaults = scratch("currentSeeds")
        let (alice, bob, _) = profiles()
        PlaybackPreferences(store: defaults).subtitleColor = .gray
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice])
        registry.activeKey = { alice }
        registry.current.playback.subtitleColor = .yellow

        registry.activeKey = { bob }
        #expect(registry.current.playback.subtitleColor == .yellow)
        #expect(registry.lastActiveKey == bob)
    }

    @Test func withoutALastActiveProfileANewOneCopiesTheDeviceValues() {
        let defaults = scratch("noLastActive")
        let (alice, _, _) = profiles()
        PlaybackPreferences(store: defaults).autoSkipIntro = true
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [])

        #expect(registry.settings(for: alice).playback.autoSkipIntro)
    }

    @Test func profilesAreIsolatedAndTheDeviceValuesAreShared() {
        let defaults = scratch("isolation")
        let (alice, bob, _) = profiles()
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice, bob])

        registry.settings(for: alice).appearance.accentChoice = .gold
        registry.settings(for: alice).playback.networkBufferDepth = .maximum

        #expect(registry.settings(for: bob).appearance.accentChoice != .gold)
        #expect(registry.legacy.appearance.accentChoice != .gold)
        #expect(registry.settings(for: bob).playback.networkBufferDepth == .maximum)
    }

    @Test func anEditEndsProvisionalForItsKindOnlyAndIsReported() {
        let defaults = scratch("edit")
        let (alice, _, _) = profiles()
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice])
        var edits: [String] = []
        registry.onLocalEdit = { key, kind in edits.append("\(key.userID).\(kind.rawValue)") }

        registry.settings(for: alice).appearance.largeCards.toggle()

        #expect(!registry.isProvisional(alice, .appearance))
        #expect(registry.isProvisional(alice, .playback))
        #expect(edits == ["alice.appearance"])
    }

    @Test func seedingAndCloudAppliesAreNotEdits() {
        let defaults = scratch("notEdits")
        let (alice, bob, _) = profiles()
        let registry = ProfileSettingsRegistry(defaults: defaults)
        var edits = 0
        registry.onLocalEdit = { _, _ in edits += 1 }
        registry.migrateIfNeeded(profiles: [alice])
        _ = registry.settings(for: bob)

        var applying = true
        registry.isApplyingCloudChanges = { applying }
        registry.settings(for: alice).playback.autoSkipOutro.toggle()
        applying = false

        #expect(edits == 0)
        #expect(registry.isProvisional(alice, .playback))
        registry.noteCloudApplied(alice, .playback)
        #expect(!registry.isProvisional(alice, .playback))
    }

    @Test func deviceEditsReportTheirLegacyRecordAndAreNoProfileEdit() {
        let defaults = scratch("deviceEdit")
        let (alice, _, _) = profiles()
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice])
        var deviceEdits: [CloudSyncStoreKey] = []
        var profileEdits = 0
        registry.onDeviceEdit = { deviceEdits.append($0) }
        registry.onLocalEdit = { _, _ in profileEdits += 1 }

        registry.settings(for: alice).playback.preferLosslessAudioBridge.toggle()
        registry.settings(for: alice).appearance.showTopShelfRow.toggle()

        #expect(deviceEdits == [.playback, .appearance])
        #expect(profileEdits == 0)
        #expect(registry.isProvisional(alice, .playback))
    }

    @Test func theLastActiveProfileSurvivesARelaunchAndFillsInBeforeLogin() {
        let defaults = scratch("lastActive")
        let (alice, _, _) = profiles()
        let first = ProfileSettingsRegistry(defaults: defaults)
        first.migrateIfNeeded(profiles: [alice])
        first.activeKey = { alice }
        first.current.appearance.accentChoice = .gold

        let relaunch = ProfileSettingsRegistry(defaults: defaults)

        #expect(relaunch.lastActiveKey == alice)
        #expect(relaunch.current.appearance.accentChoice == .gold)
    }

    @Test func aHomeChangeOnTheActiveProfileIsAnEdit() {
        let defaults = scratch("homeEdit")
        let (alice, _, _) = profiles()
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice])
        registry.activeKey = { alice }
        var edits: [ProfileRecordKind] = []
        registry.onLocalEdit = { key, kind in if key == alice { edits.append(kind) } }

        NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)

        #expect(edits == [.home])
        #expect(!registry.isProvisional(alice, .home))
    }

    @Test func resetDropsEveryCachedProfile() {
        let suite = "profileRegistry.reset"
        let defaults = scratch("reset")
        let (alice, _, _) = profiles()
        let registry = ProfileSettingsRegistry(defaults: defaults)
        registry.migrateIfNeeded(profiles: [alice])
        registry.settings(for: alice).playback.autoSkipIntro = true

        defaults.removePersistentDomain(forName: suite)
        registry.resetAll()

        #expect(!registry.hasValues(alice))
        #expect(registry.lastActiveKey == nil)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix(alice.storageScope) })
    }
}
