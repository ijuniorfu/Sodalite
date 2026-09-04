import Foundation

/// Pure gate decisions for the Guardian PIN. The container holds the stores and the active-session
/// pointers; everything that is a judgement lives here so it can be asserted without them.
enum ParentalGatePolicy {

    /// Whether activating a profile of `targetRole` costs the PIN, given the role of the profile
    /// that is active right now and whether this is a cold start (nobody identified themselves yet).
    static func gateRequiredForActivating(targetRole: ProfileLockRole,
                                          activeRole: ProfileLockRole,
                                          isColdStart: Bool) -> Bool {
        switch targetRole {
        case .pinToLeave:
            // Walking into a locked-in profile is free; the lock is on the way out.
            return false
        case .pinToEnter:
            return true
        case .open:
            return isColdStart || activeRole == .pinToLeave
        }
    }

    static func reason(forActivating targetRole: ProfileLockRole) -> PINReason {
        targetRole == .pinToEnter ? .enterProfile : .switchProfile
    }
}
