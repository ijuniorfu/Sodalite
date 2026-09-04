import Testing
@testable import Sodalite

struct GuardianPINRecoveryCandidatesTests {
    private func pick(_ roles: [String: ProfileLockRole]) -> [String] {
        GuardianPINRecoveryCandidates
            .candidates(roles.keys.sorted(), role: { roles[$0] ?? .open })
    }

    /// A household with entry locks: only a profile a PIN holder may enter proves guardianship.
    @Test func entryLockedProfilesWinWhenPresent() {
        #expect(pick(["dad": .pinToEnter, "family": .pinToEnter, "kid": .open, "locked": .pinToLeave])
                == ["dad", "family"])
    }

    /// Today's rule survives untouched for installs that never set an entry lock.
    @Test func withoutEntryLocksTheOpenProfilesRemainCandidates() {
        #expect(pick(["dad": .open, "kid": .pinToLeave]) == ["dad"])
    }

    /// A leave-locked profile is the child's, in either branch.
    @Test func leaveLockedProfilesAreNeverCandidates() {
        #expect(pick(["kid": .pinToLeave]).isEmpty)
        #expect(pick(["kid": .pinToLeave, "teen": .pinToLeave]).isEmpty)
    }

    @Test func anEmptyListStaysEmpty() {
        #expect(pick([:]).isEmpty)
    }
}
