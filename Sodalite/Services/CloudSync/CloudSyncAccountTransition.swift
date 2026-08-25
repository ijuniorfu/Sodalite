import Foundation

/// Which iCloud account the sync engine is about to talk to, measured against the one
/// this device last adopted against.
///
/// The distinction that carries the weight is `nil` versus a different name. A device
/// that never adopted has no account to be moved away from, so its first upload is the
/// intended "bring my servers onto this device" flow. A device that already adopted and
/// now reports a different account has changed hands, and adopting again there would
/// push the previous account's servers, and with them its Jellyfin tokens, passwords and
/// Seerr sessions, into a stranger's private database.
enum CloudSyncAccountTransition: Equatable {
    /// Nothing was ever recorded: adopt normally.
    case firstAdoption
    /// The same account as last time: carry on.
    case unchanged
    /// A different iCloud account than the one this device adopted against.
    case changed

    /// Deliberately takes only the two record names, so the decision can be tested without
    /// a CloudKit container and so no account identifier has to travel any further.
    static func resolve(stored: String?, current: String) -> CloudSyncAccountTransition {
        guard let stored else { return .firstAdoption }
        return stored == current ? .unchanged : .changed
    }
}
