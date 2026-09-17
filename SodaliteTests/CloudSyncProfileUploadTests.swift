import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync uploads profile records", .serialized)
@MainActor
struct CloudSyncProfileUploadTests {
    private func scratch(_ name: String) -> UserDefaults {
        let suite = "profileUpload.\(name).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func setUp(_ name: String) -> (DependencyContainer, CloudSyncService, CloudSyncPreferences, ProfileKey, ProfileKey) {
        let server = "up-\(UUID().uuidString)"
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: scratch(name))
        let alice = ProfileKey(serverID: server, userID: "alice")
        let bob = ProfileKey(serverID: server, userID: "bob")
        container.profileSettings.migrateIfNeeded(profiles: [alice, bob])
        let prefs = CloudSyncPreferences(store: scratch("\(name).sync"))
        let service = CloudSyncService(dependencies: container, preferences: prefs)
        return (container, service, prefs, alice, bob)
    }

    @Test func adoptionUploadsEditedKindsOnly() {
        let (container, service, prefs, alice, bob) = setUp("adoption")
        container.profileSettings.settings(for: alice).playback.autoSkipIntro.toggle()

        service.completeAdoption()
        let saves = Set(prefs.drainPendingChanges().saves)

        #expect(saves.contains(CloudSyncRecordName.profile(.playback, alice)))
        #expect(!saves.contains(CloudSyncRecordName.profile(.appearance, alice)))
        #expect(!saves.contains { $0.hasSuffix(bob.storageScope) })
    }

    @Test func aProvisionalProfileNeverUploads() {
        let (container, service, prefs, _, bob) = setUp("provisional")

        service.uploadProfileIfChanged(.playback, bob)

        #expect(prefs.drainPendingChanges().saves.isEmpty)
        // The service holds its container unowned, as the app's one container outlives it.
        withExtendedLifetime(container) {}
    }

    @Test func theUploadCarriesTheProfileItWasScheduledFor() {
        let (container, service, prefs, alice, bob) = setUp("captured")
        container.profileSettings.settings(for: alice).appearance.largeCards.toggle()
        container.profileSettings.activeKey = { bob }

        service.uploadProfileIfChanged(.appearance, alice)

        #expect(prefs.drainPendingChanges().saves == [CloudSyncRecordName.profile(.appearance, alice)])
    }

    @Test func anUnchangedProfileIsNotUploadedTwice() {
        let (container, service, prefs, alice, _) = setUp("twice")
        container.profileSettings.settings(for: alice).playback.autoSkipOutro.toggle()

        service.uploadProfileIfChanged(.playback, alice)
        _ = prefs.drainPendingChanges()
        service.uploadProfileIfChanged(.playback, alice)

        #expect(prefs.drainPendingChanges().saves.isEmpty)
    }

    @Test func aZoneRecreationStillReuploadsEditedProfiles() {
        let (container, service, prefs, alice, _) = setUp("zone")
        container.profileSettings.settings(for: alice).appearance.largeCards.toggle()
        service.uploadProfileIfChanged(.appearance, alice)
        _ = prefs.drainPendingChanges()

        prefs.resetForZoneRecreation()
        service.completeAdoption()

        #expect(prefs.drainPendingChanges().saves.contains(CloudSyncRecordName.profile(.appearance, alice)))
    }
}
