import Foundation
import Observation

/// Launch behavior for multi-profile servers. UserDefaults-backed (no secrets, just IDs + picker toggle).
@Observable
@MainActor
final class AuthPreferences {

    enum LaunchBehavior: String, CaseIterable, Sendable {
        case showPicker
        /// Restore `defaultUserID` directly; silently falls back to the picker if that ID is no longer remembered.
        case useDefault
    }

    // MARK: - Keys

    private enum Keys {
        static let launchBehavior = "auth.launchBehavior"
        static let defaultUserID = "auth.defaultUserID"
        static let defaultServerID = "auth.defaultServerID"
    }

    // MARK: - State

    var launchBehavior: LaunchBehavior {
        didSet { store.set(launchBehavior.rawValue, forKey: Keys.launchBehavior) }
    }

    /// Nil means no default set yet: the picker shows regardless of launch behavior.
    var defaultUserID: String? {
        didSet {
            if let defaultUserID, !defaultUserID.isEmpty {
                store.set(defaultUserID, forKey: Keys.defaultUserID)
            } else {
                store.removeObject(forKey: Keys.defaultUserID)
            }
        }
    }

    /// Server auto-promoted to active on cold launch. Nil keeps the most-recently-used; cleared when the server is removed.
    var defaultServerID: String? {
        didSet {
            if let defaultServerID, !defaultServerID.isEmpty {
                store.set(defaultServerID, forKey: Keys.defaultServerID)
            } else {
                store.removeObject(forKey: Keys.defaultServerID)
            }
        }
    }

    // MARK: - Init

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        let raw = store.string(forKey: Keys.launchBehavior) ?? LaunchBehavior.showPicker.rawValue
        self.launchBehavior = LaunchBehavior(rawValue: raw) ?? .showPicker
        self.defaultUserID = store.string(forKey: Keys.defaultUserID)
        self.defaultServerID = store.string(forKey: Keys.defaultServerID)
    }
}
