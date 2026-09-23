import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync preferences bookkeeping")
struct CloudSyncPreferencesTests {
    private func makePrefs() -> CloudSyncPreferences {
        let defaults = UserDefaults(suiteName: "CloudSyncPreferencesTests-\(UUID().uuidString)")!
        return CloudSyncPreferences(store: defaults)
    }

    @Test("enabled defaults to true")
    func defaultEnabled() {
        #expect(makePrefs().isEnabled == true)
    }

    @Test("the account-change lock is off until something sets it")
    func accountChangeLockDefaultsOff() {
        #expect(makePrefs().accountChangeLocked == false)
    }

    @Test("the account-change lock survives a relaunch, because the status row does not")
    func accountChangeLockPersists() {
        let suite = "CloudSyncPreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = CloudSyncPreferences(store: defaults)
        first.accountChangeLocked = true
        first.isEnabled = false

        let relaunched = CloudSyncPreferences(store: UserDefaults(suiteName: suite)!)
        #expect(relaunched.accountChangeLocked == true)
        #expect(relaunched.isEnabled == false)
    }

    @Test("nextStamp is strictly increasing even within the same instant")
    func monotonicStamps() {
        let prefs = makePrefs()
        let a = prefs.nextStamp()
        let b = prefs.nextStamp()
        #expect(b > a)
    }

    @Test("nextStamp outranks a noted remote stamp from a skewed clock")
    func outranksRemote() {
        let prefs = makePrefs()
        let future = Date().addingTimeInterval(3600)
        prefs.noteRemoteStamp(future)
        #expect(prefs.nextStamp() > future)
    }

    @Test("local stamps and system fields persist per record and reset on account change")
    func perRecordCaches() {
        let prefs = makePrefs()
        let stamp = Date(timeIntervalSince1970: 123)
        prefs.setLocalStamp(stamp, for: "server-x")
        prefs.setSystemFields(Data([1, 2, 3]), for: "server-x")
        #expect(prefs.localStamp(for: "server-x") == stamp)
        #expect(prefs.systemFields(for: "server-x") == Data([1, 2, 3]))
        prefs.removeRecordCaches(for: "server-x")
        #expect(prefs.localStamp(for: "server-x") == nil)
        #expect(prefs.systemFields(for: "server-x") == nil)

        prefs.adoptionCompleted = true
        prefs.setLocalStamp(stamp, for: "settings-playback")
        prefs.engineState = Data([9])
        prefs.accountID = "acct-1"
        prefs.resetForAccountChange()
        #expect(prefs.adoptionCompleted == false)
        #expect(prefs.localStamp(for: "settings-playback") == nil)
        #expect(prefs.engineState == nil)
        #expect(prefs.accountID == nil)
    }

    @Test("pending stash persists, dedupes, supersedes both ways, drain clears")
    func pendingStash() {
        let prefs = makePrefs()
        prefs.stashPendingSave("server-a")
        prefs.stashPendingSave("server-a")
        prefs.stashPendingSave("settings-playback")
        prefs.stashPendingDelete("server-a")
        prefs.stashPendingSave("server-a")
        let drained = prefs.drainPendingChanges()
        // server-a trails settings-playback: the delete removed the original save
        // entry, then the re-save appended it fresh and cleared the delete.
        #expect(drained.saves == ["settings-playback", "server-a"])
        #expect(drained.deletes.isEmpty)
        let empty = prefs.drainPendingChanges()
        #expect(empty.saves.isEmpty && empty.deletes.isEmpty)
    }

    @Test("account change reset clears the pending stash")
    func resetClearsStash() {
        let prefs = makePrefs()
        prefs.stashPendingSave("server-a")
        prefs.stashPendingDelete("security")
        prefs.resetForAccountChange()
        let drained = prefs.drainPendingChanges()
        #expect(drained.saves.isEmpty && drained.deletes.isEmpty)
    }
}

@Suite("CloudSync outbox keeps what has not landed")
struct CloudSyncOutboxTests {
    private func prefs() -> CloudSyncPreferences {
        CloudSyncPreferences(store: UserDefaults(suiteName: "outbox.\(UUID().uuidString)")!)
    }

    @Test func aDeleteStaysUntilConfirmed() {
        let p = prefs()
        p.stashPendingDelete("security")
        #expect(p.drainPendingChanges().deletes == ["security"])

        p.stashPendingDelete("security")
        p.unstashPendingDelete("security")
        #expect(p.drainPendingChanges().deletes.isEmpty)
    }

    /// An edit that lands after its record was built for a send must go again once that send lands.
    @Test func anEditAfterTheBuildIsSentAgain() {
        let built = Date(timeIntervalSince1970: 100)
        #expect(CloudSyncService.editedWhileInFlight(sent: built, local: built.addingTimeInterval(1)))
        #expect(!CloudSyncService.editedWhileInFlight(sent: built, local: built))
        #expect(!CloudSyncService.editedWhileInFlight(sent: nil, local: built))
    }
}

@Suite("CloudSync gives up on a record it can never read")
struct CloudSyncSkippedRetryTests {
    @Test func aRecordIsRetriedAFewStartsThenDropped() {
        let p = CloudSyncPreferences(store: UserDefaults(suiteName: "skipped.\(UUID().uuidString)")!)
        p.noteSkippedRecord("profile-x")

        for _ in 1 ..< CloudSyncPreferences.maxSkippedRetries {
            #expect(!p.noteSkippedRetryFailed("profile-x"))
            #expect(p.skippedRecords == ["profile-x"])
        }
        #expect(p.noteSkippedRetryFailed("profile-x"))
        #expect(p.skippedRecords.isEmpty)
    }

    @Test func readingItOnceResetsTheCount() {
        let p = CloudSyncPreferences(store: UserDefaults(suiteName: "skipped.\(UUID().uuidString)")!)
        p.noteSkippedRecord("r")
        _ = p.noteSkippedRetryFailed("r")
        p.clearSkippedRecord("r")
        p.noteSkippedRecord("r")
        for _ in 1 ..< CloudSyncPreferences.maxSkippedRetries {
            #expect(!p.noteSkippedRetryFailed("r"))
        }
    }
}
