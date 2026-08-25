import CryptoKit
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

extension CloudSyncAccountTransition {
    var logDescription: String {
        switch self {
        case .firstAdoption: "first adoption on this device"
        case .unchanged: "same iCloud account as the last run"
        case .changed: "a different iCloud account than the last run"
        }
    }

    /// Short, stable, one-way stand-in for an iCloud user record name, so the diagnostic log can
    /// answer "did these two runs talk to the same account" without carrying the identifier itself.
    static func fingerprint(_ recordName: String) -> String {
        SHA256.hash(data: Data(recordName.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
