import CloudKit
import Foundation
import Testing
@testable import Sodalite

/// What an iCloud sign-out or account switch while the app runs does to the sync bookkeeping, and why
/// a launch no longer re-uploads settings nobody changed.
@Suite("CloudSync account changes and launch uploads", .serialized)
@MainActor
struct CloudSyncAccountChangeTests {
    private func setUp(_ name: String) -> (DependencyContainer, CloudSyncService, CloudSyncPreferences) {
        let defaults = UserDefaults(suiteName: "accountChange.\(name).\(UUID().uuidString)")!
        let container = DependencyContainer(keychainService: InMemoryKeychain(), defaults: defaults)
        let prefs = CloudSyncPreferences(store: UserDefaults(suiteName: "accountChange.\(name).sync.\(UUID().uuidString)")!)
        prefs.accountID = "_account-a"
        prefs.adoptionCompleted = true
        prefs.setLocalStamp(Date(timeIntervalSince1970: 100), for: CloudSyncRecordName.settings(.auth))
        return (container, CloudSyncService(dependencies: container, preferences: prefs), prefs)
    }

    /// The leak this closes: a sign-out wiped the account id, so the start after the next sign-in read
    /// as a first adoption and uploaded every server's credentials into whatever account that was.
    @Test func aSignOutKeepsTheAccountSoTheNextStartCanTellWhoCameBack() {
        let (container, service, prefs) = setUp("signOut")

        service.applyAccountChange(.signOut(previousUser: CKRecord.ID(recordName: "_account-a")))

        #expect(prefs.accountID == "_account-a")
        #expect(prefs.adoptionCompleted)
        #expect(prefs.localStamp(for: CloudSyncRecordName.settings(.auth)) != nil)
        #expect(prefs.isEnabled)
        #expect(service.status == .noAccount)
        #expect(CloudSyncAccountTransition.resolve(stored: prefs.accountID, current: "_account-b") == .changed)
        #expect(CloudSyncAccountTransition.resolve(stored: prefs.accountID, current: "_account-a") == .unchanged)
        withExtendedLifetime(container) {}
    }

    @Test func aSwitchLocksSyncOutInsteadOfAdoptingTheNewAccount() {
        let (container, service, prefs) = setUp("switch")

        service.applyAccountChange(.switchAccounts(
            previousUser: CKRecord.ID(recordName: "_account-a"),
            currentUser: CKRecord.ID(recordName: "_account-b")
        ))

        #expect(!prefs.isEnabled)
        #expect(prefs.accountChangeLocked)
        #expect(service.status == .accountChanged)
        withExtendedLifetime(container) {}
    }

    /// Vincent's device log showed six settings records going up on every launch with no edit. The
    /// observers fire on the session restore, and against an empty snapshot that read as a change.
    @Test func aLaunchWithoutAnEditUploadsNothing() {
        let (container, service, prefs) = setUp("launch")
        _ = prefs.drainPendingChanges()

        service.seedSettingsSnapshots()
        for key in CloudSyncStoreKey.allCases where !key.isProfileBacked {
            service.uploadSettingsIfChanged(key)
        }

        #expect(prefs.drainPendingChanges().saves.isEmpty)
        withExtendedLifetime(container) {}
    }

    @Test func aRealEditAfterTheSeedStillUploads() {
        let (container, service, prefs) = setUp("edit")
        _ = prefs.drainPendingChanges()
        service.seedSettingsSnapshots()

        container.seerrNotificationPreferences.notifyPendingRequests.toggle()
        service.uploadSettingsIfChanged(.seerrNotifications)

        #expect(prefs.drainPendingChanges().saves == [CloudSyncRecordName.settings(.seerrNotifications)])
    }
}
