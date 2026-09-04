import Testing
import Foundation
@testable import Sodalite

@MainActor
struct ParentalControlsRoleTests {
    private func store(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "role.\(name)")!
        defaults.removePersistentDomain(forName: "role.\(name)")
        return defaults
    }

    @Test func freshStoreReadsEveryProfileAsOpen() {
        let prefs = ParentalControlsPreferences(store: store("fresh"))
        #expect(prefs.role(serverID: "s1", userID: "u1") == .open)
        #expect(prefs.hasAnyLockedProfile == false)
    }

    /// The migration: an install from before this feature carries only the legacy set, and every
    /// profile in it must keep behaving exactly as it did, which is "free to enter, PIN to leave".
    @Test func legacyProtectedIDsReadAsPinToLeave() {
        let defaults = store("legacy")
        defaults.set(["s1:kid"], forKey: "parental.protectedProfileIDs")
        let prefs = ParentalControlsPreferences(store: defaults)
        #expect(prefs.role(serverID: "s1", userID: "kid") == .pinToLeave)
        #expect(prefs.role(serverID: "s1", userID: "dad") == .open)
        #expect(prefs.hasAnyLockedProfile)
    }

    @Test func setRoleKeepsTheTwoSetsExclusive() {
        let prefs = ParentalControlsPreferences(store: store("exclusive"))
        prefs.setRole(.pinToLeave, serverID: "s1", userID: "u1")
        #expect(prefs.protectedProfileIDs.contains("s1:u1"))
        #expect(prefs.entryLockedProfileIDs.isEmpty)

        prefs.setRole(.pinToEnter, serverID: "s1", userID: "u1")
        #expect(prefs.protectedProfileIDs.isEmpty)
        #expect(prefs.entryLockedProfileIDs.contains("s1:u1"))
        #expect(prefs.role(serverID: "s1", userID: "u1") == .pinToEnter)

        prefs.setRole(.open, serverID: "s1", userID: "u1")
        #expect(prefs.protectedProfileIDs.isEmpty)
        #expect(prefs.entryLockedProfileIDs.isEmpty)
        #expect(prefs.role(serverID: "s1", userID: "u1") == .open)
    }

    /// Gap 1 from the spec: locking adults out must not require locking a child in.
    @Test func entryLockAloneCountsAsLocked() {
        let prefs = ParentalControlsPreferences(store: store("entryOnly"))
        prefs.setRole(.pinToEnter, serverID: "s1", userID: "dad")
        #expect(prefs.hasAnyLockedProfile)
        #expect(prefs.protectedProfileIDs.isEmpty)
    }

    /// Only reachable through a corrupted store or a half-applied cloud record. Reading the pair as
    /// the stricter role keeps a corruption from quietly opening a profile.
    @Test func aKeyInBothSetsReadsAsPinToLeave() {
        let defaults = store("corrupt")
        defaults.set(["s1:u1"], forKey: "parental.protectedProfileIDs")
        defaults.set(["s1:u1"], forKey: "parental.entryLockedProfileIDs")
        let prefs = ParentalControlsPreferences(store: defaults)
        #expect(prefs.role(serverID: "s1", userID: "u1") == .pinToLeave)
    }

    @Test func entryLockPersistsUnderItsOwnKey() {
        let defaults = store("persist")
        let prefs = ParentalControlsPreferences(store: defaults)
        prefs.setRole(.pinToEnter, serverID: "s1", userID: "u1")
        #expect(defaults.array(forKey: "parental.entryLockedProfileIDs") as? [String] == ["s1:u1"])
    }
}
