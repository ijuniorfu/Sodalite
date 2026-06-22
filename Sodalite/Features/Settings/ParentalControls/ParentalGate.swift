import Foundation
import Observation

/// Why the Guardian-PIN is being requested. Drives the prompt copy.
enum PINReason: Equatable {
    case switchProfile      // activate an unprotected profile
    case logout
    case serverManagement
    case openParentalSettings
}

/// Presentation coordinator: challenge(reason:) suspends until PINEntryView resolves it; AppRouter drives the fullScreenCover. Decision logic lives on DependencyContainer; this holds no container ref so no retain cycle.
@Observable
@MainActor
final class ParentalGate {

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let reason: PINReason
    }

    private(set) var activeRequest: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Awaits outcome (true = unlocked, false = cancelled). Caller must have already decided a PIN is required.
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
