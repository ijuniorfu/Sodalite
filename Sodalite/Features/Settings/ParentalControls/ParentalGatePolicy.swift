import Foundation

/// Pure gate decisions for the Guardian PIN. The container holds the stores and the active-session
/// pointers; everything that is a judgement lives here so it can be asserted without them.
enum ParentalGatePolicy {

    /// Whether activating a profile of `targetRole` costs the PIN, given the role of the profile
    /// that is active right now.
    ///
    /// There is no cold-start term any more. A lock is a property of the door, and before #105 the
    /// cold-start prompt was how an unmarked profile expressed one; the migration reads those as
    /// `pinToEnter`, which says the same thing at every hour. At a cold start there is no session,
    /// so `activeRole` is `.open` and only the door decides.
    static func gateRequiredForActivating(targetRole: ProfileLockRole,
                                          activeRole: ProfileLockRole) -> Bool {
        switch targetRole {
        case .pinToLeave:
            // Walking into a locked-in profile is free; the lock is on the way out.
            return false
        case .pinToEnter:
            return true
        case .open:
            // Open means open, except as the far side of somebody else's leave-lock: this is the
            // branch that actually enforces pinToLeave, so it cannot go free.
            return activeRole == .pinToLeave
        }
    }

    /// Whether a session-scoped escape (logout, server management, tabs, Seerr, iCloud, support,
    /// the profile screen) costs the PIN.
    ///
    /// Only a profile that cannot be opened without the PIN carries a trusted occupant. An open
    /// profile is by construction reachable by anyone, and a locked-in one is where the child sits,
    /// so both are gated. Reading trust off the role rather than the person is the cheap proxy
    /// available; the one screen that can disable all of it asks regardless (see SettingsView).
    static func sessionActionRequiresPIN(activeRole: ProfileLockRole) -> Bool {
        activeRole != .pinToEnter
    }

    static func reason(forActivating targetRole: ProfileLockRole) -> PINReason {
        targetRole == .pinToEnter ? .enterProfile : .switchProfile
    }
}
