import Foundation

/// Which profiles' Jellyfin passwords may reset the Guardian PIN.
///
/// Recovery proves guardianship with a password, so it has to ask for the password of the most
/// privileged class of profile in the household. An entry-locked profile is by definition one only
/// a PIN holder may open, so its password is a guardian credential; an open profile in a household
/// that HAS entry locks is not, and accepting it would hand a child the reset.
enum GuardianPINRecoveryCandidates {
    static func candidates<Profile>(_ profiles: [Profile],
                                    role: (Profile) -> ProfileLockRole) -> [Profile] {
        let entryLocked = profiles.filter { role($0) == .pinToEnter }
        if !entryLocked.isEmpty { return entryLocked }
        return profiles.filter { role($0) != .pinToLeave }
    }
}
