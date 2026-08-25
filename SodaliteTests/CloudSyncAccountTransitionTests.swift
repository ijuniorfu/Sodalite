import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync iCloud account transition")
struct CloudSyncAccountTransitionTests {

    @Test("a device that never adopted is not treated as having switched accounts")
    func nilStoredIsFirstAdoption() {
        #expect(CloudSyncAccountTransition.resolve(stored: nil, current: "_alice") == .firstAdoption)
    }

    @Test("the same account is not a switch")
    func sameAccountIsUnchanged() {
        #expect(CloudSyncAccountTransition.resolve(stored: "_alice", current: "_alice") == .unchanged)
    }

    @Test("a different account than the adopted one is a switch")
    func differentAccountIsChanged() {
        #expect(CloudSyncAccountTransition.resolve(stored: "_alice", current: "_bob") == .changed)
    }

    @Test("an empty stored name is still a name, not an absent one")
    func emptyStoredNameIsNotFirstAdoption() {
        #expect(CloudSyncAccountTransition.resolve(stored: "", current: "_bob") == .changed)
        #expect(CloudSyncAccountTransition.resolve(stored: "", current: "") == .unchanged)
    }

    @Test("the fingerprint is stable, short, and separates two accounts")
    func fingerprintIsStableAndDistinct() {
        let alice = CloudSyncAccountTransition.fingerprint("_alice")
        #expect(alice == CloudSyncAccountTransition.fingerprint("_alice"))
        #expect(alice != CloudSyncAccountTransition.fingerprint("_bob"))
        #expect(alice.count == 8)
    }

    @Test("the fingerprint does not carry the record name it stands for")
    func fingerprintDoesNotLeakTheName() {
        #expect(!CloudSyncAccountTransition.fingerprint("_alice").contains("alice"))
    }

    @Test("every outcome names itself for the log, including the quiet ones")
    func everyOutcomeIsLoggable() {
        let described = [
            CloudSyncAccountTransition.firstAdoption,
            .unchanged,
            .changed,
        ].map(\.logDescription)
        #expect(Set(described).count == 3)
        #expect(described.allSatisfy { !$0.isEmpty })
    }

    @Test("record names compare exactly, case included")
    func comparisonIsExact() {
        #expect(CloudSyncAccountTransition.resolve(stored: "_Alice", current: "_alice") == .changed)
    }
}
