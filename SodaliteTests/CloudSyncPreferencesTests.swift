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

    @Test("pending stash persists, dedupes, delete supersedes save, drain clears")
    func pendingStash() {
        let prefs = makePrefs()
        prefs.stashPendingSave("server-a")
        prefs.stashPendingSave("server-a")
        prefs.stashPendingSave("settings-playback")
        prefs.stashPendingDelete("server-a")
        let drained = prefs.drainPendingChanges()
        #expect(drained.saves == ["settings-playback"])
        #expect(drained.deletes == ["server-a"])
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
