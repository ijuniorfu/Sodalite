import Foundation
import Observation

/// Why the Guardian-PIN is being requested. Drives the prompt copy.
enum PINReason: Equatable {
    case switchProfile      // activate an unprotected profile
    case logout
    case serverManagement
    case openParentalSettings
}

/// Presentation coordinator for the Guardian-PIN challenge. Owns an
/// async `challenge(reason:)` that suspends until `PINEntryView` resolves
/// it. AppRouter observes `activeRequest` and drives the fullScreenCover.
///
/// Decision logic ("is a PIN required?") lives on DependencyContainer,
/// which has the keychain + preference state. This object only manages
/// presentation, so it carries no reference to the container and creates
/// no retain cycle.
@Observable
@MainActor
final class ParentalGate {

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let reason: PINReason
    }

    private(set) var activeRequest: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Present the PIN entry and await the outcome (true = unlocked,
    /// false = cancelled). Caller must have already decided a PIN is
    /// required (see DependencyContainer.parentalGateRequired...).
    func challenge(reason: PINReason) async -> Bool {
        // Defensive: if a prior challenge somehow never resolved, fail it.
        continuation?.resume(returning: false)
        continuation = nil
        return await withCheckedContinuation { cont in
            continuation = cont
            activeRequest = Request(reason: reason)
        }
    }

    /// Called by PINEntryView on success (true) or cancel (false).
    func resolve(_ unlocked: Bool) {
        activeRequest = nil
        continuation?.resume(returning: unlocked)
        continuation = nil
    }
}
