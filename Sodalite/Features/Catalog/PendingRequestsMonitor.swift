import Foundation
import Observation

/// Single source of truth for the count of Jellyseerr requests pending approval (admin only).
/// The Catalog tab badge and the background refresh handler both read this. Eligibility and the
/// actual network fetch are injected closures so the monitor is decoupled from AppState / services
/// and trivially testable; DependencyContainer wires them in `wirePendingRequestsMonitor()`.
@Observable
@MainActor
final class PendingRequestsMonitor {
    private(set) var pendingApprovalCount: Int?

    /// True when the active Seerr user may manage requests and is connected.
    @ObservationIgnored var isEligible: @MainActor () -> Bool = { false }
    /// Fetches the current pending-approval count from Jellyseerr.
    @ObservationIgnored var fetchPendingCount: () async throws -> Int = { 0 }

    init() {}

    /// Fetch + publish the pending count. No-op unless eligible. On failure the prior value stands.
    /// This owns only the live count (the Catalog tab badge). The notification baseline
    /// (`lastSeenPendingCount`) is the notification path's concern, not the monitor's.
    func refresh() async {
        guard isEligible() else { return }
        do {
            pendingApprovalCount = try await fetchPendingCount()
        } catch {
            // Keep the previous value; never clobber to nil/0 on a transient failure.
        }
    }

    func reset() {
        pendingApprovalCount = nil
    }

    /// Notify only when the count genuinely rose since the last observation.
    static func shouldNotify(current: Int, lastSeen: Int) -> Bool {
        current > lastSeen
    }
}
