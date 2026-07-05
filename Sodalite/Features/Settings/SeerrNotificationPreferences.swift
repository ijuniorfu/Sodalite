import Foundation
import Observation

/// Device-local (UserDefaults) opt-in + baseline for the pending-requests notification feature;
/// read/write via `DependencyContainer.seerrNotificationPreferences`. Sole owner of its two keys.
@Observable
@MainActor
final class SeerrNotificationPreferences {
    private enum Keys {
        static let notifyPendingRequests = "seerr.notifyPendingRequests"
        static let lastSeenPendingCount = "seerr.lastSeenPendingCount"
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.notifyPendingRequests = defaults.bool(forKey: Keys.notifyPendingRequests)
        self.lastSeenPendingCount = defaults.integer(forKey: Keys.lastSeenPendingCount)
    }

    var notifyPendingRequests: Bool {
        didSet { defaults.set(notifyPendingRequests, forKey: Keys.notifyPendingRequests) }
    }

    var lastSeenPendingCount: Int {
        didSet { defaults.set(lastSeenPendingCount, forKey: Keys.lastSeenPendingCount) }
    }
}
