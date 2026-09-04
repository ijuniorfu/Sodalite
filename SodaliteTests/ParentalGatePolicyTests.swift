import Testing
import Foundation
@testable import Sodalite

/// The full matrix, including the three rows that must NOT change. The claim "existing installs
/// behave exactly as before" rests on those rows being copied rather than re-derived, so they are
/// pinned here on purpose.
struct ParentalGatePolicyTests {

    // MARK: entering a leave-locked (today's "protected") profile is always free

    @Test func enteringALeaveLockedProfileIsFreeAtColdStart() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToLeave, activeRole: .open, isColdStart: true) == false)
    }

    @Test func enteringALeaveLockedProfileIsFreeFromALeaveLockedOne() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToLeave, activeRole: .pinToLeave, isColdStart: false) == false)
    }

    // MARK: an open profile keeps today's rule

    @Test func openProfileIsGatedAtColdStart() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .open, activeRole: .open, isColdStart: true))
    }

    @Test func openProfileIsGatedWhenLeavingALeaveLockedProfile() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .open, activeRole: .pinToLeave, isColdStart: false))
    }

    @Test func openProfileIsFreeOnAWarmSwitchFromAnotherOpenProfile() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .open, activeRole: .open, isColdStart: false) == false)
    }

    // MARK: the new rule

    @Test func entryLockedProfileIsGatedAtColdStart() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToEnter, activeRole: .open, isColdStart: true))
    }

    @Test func entryLockedProfileIsGatedOnAWarmSwitch() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToEnter, activeRole: .open, isColdStart: false))
    }

    @Test func entryLockedProfileIsGatedEvenFromAnotherEntryLockedProfile() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToEnter, activeRole: .pinToEnter, isColdStart: false))
    }

    /// The reprompt's "continue as current" taps the ACTIVE card, so target and active are the same
    /// profile. Only the entry-locked reading may cost the PIN there; the other two continue free,
    /// exactly as they did before #105.
    @Test func continuingAsTheCurrentProfileIsGatedOnlyWhenItIsEntryLocked() {
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToEnter, activeRole: .pinToEnter, isColdStart: false))
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .open, activeRole: .open, isColdStart: false) == false)
        #expect(ParentalGatePolicy.gateRequiredForActivating(
            targetRole: .pinToLeave, activeRole: .pinToLeave, isColdStart: false) == false)
    }

    // MARK: prompt copy

    @Test func entryLockedTargetGetsItsOwnPrompt() {
        #expect(ParentalGatePolicy.reason(forActivating: .pinToEnter) == .enterProfile)
    }

    @Test func everyOtherTargetKeepsTheSwitchPrompt() {
        #expect(ParentalGatePolicy.reason(forActivating: .open) == .switchProfile)
        #expect(ParentalGatePolicy.reason(forActivating: .pinToLeave) == .switchProfile)
    }
}

/// `parentalControlsActive()` is a conjunction of a keychain read and a store read, and only the
/// container sees both halves. The store behind it is `UserDefaults.standard`, shared with every
/// other suite, so each test puts it back the way it found it.
@MainActor
struct ParentalControlsActiveTests {
    /// Gap 1 from the spec: an entry lock alone arms parental controls, with nobody locked in.
    @Test func entryLockAloneArmsParentalControls() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        try container.saveGuardianPIN("1234")
        container.parentalControlsPreferences.setRole(.pinToEnter, serverID: "A", userID: "dad")
        defer { container.parentalControlsPreferences.setRole(.open, serverID: "A", userID: "dad") }
        #expect(container.parentalControlsPreferences.protectedProfileIDs.isEmpty)
        #expect(container.parentalControlsActive())
    }

    @Test func aPinWithNoLockedProfileIsNotActive() throws {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        try container.saveGuardianPIN("1234")
        let previousProtected = container.parentalControlsPreferences.protectedProfileIDs
        let previousEntry = container.parentalControlsPreferences.entryLockedProfileIDs
        container.parentalControlsPreferences.protectedProfileIDs = []
        container.parentalControlsPreferences.entryLockedProfileIDs = []
        defer {
            container.parentalControlsPreferences.protectedProfileIDs = previousProtected
            container.parentalControlsPreferences.entryLockedProfileIDs = previousEntry
        }
        #expect(container.parentalControlsActive() == false)
    }

    @Test func locksWithoutAPinAreNotActive() {
        let container = DependencyContainer(keychainService: InMemoryKeychain())
        container.parentalControlsPreferences.setRole(.pinToEnter, serverID: "A", userID: "dad")
        defer { container.parentalControlsPreferences.setRole(.open, serverID: "A", userID: "dad") }
        #expect(container.parentalControlsActive() == false)
    }
}
