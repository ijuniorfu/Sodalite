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

    /// How long the app must sit in the background before the profile picker reappears
    /// on return (issue #41). Only meaningful while launchBehavior == .showPicker.
    enum ProfileRepromptInterval: String, CaseIterable, Sendable {
        case off
        case immediately
        case after30s
        case after1min
        case after5min
        case after15min
        case after60min

        /// Minimum background duration before reprompting; nil disables the reprompt.
        var threshold: Duration? {
            switch self {
            case .off: nil
            case .immediately: .zero
            case .after30s: .seconds(30)
            case .after1min: .seconds(60)
            case .after5min: .seconds(300)
            case .after15min: .seconds(900)
            case .after60min: .seconds(3600)
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let launchBehavior = "auth.launchBehavior"
        static let defaultUserID = "auth.defaultUserID"
        static let defaultServerID = "auth.defaultServerID"
        static let profileReprompt = "auth.profileReprompt"
    }

    // MARK: - State

    var launchBehavior: LaunchBehavior {
        didSet { store.set(launchBehavior.rawValue, forKey: Keys.launchBehavior) }
    }

    var profileReprompt: ProfileRepromptInterval {
        didSet { store.set(profileReprompt.rawValue, forKey: Keys.profileReprompt) }
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
        let repromptRaw = store.string(forKey: Keys.profileReprompt) ?? ProfileRepromptInterval.off.rawValue
        self.profileReprompt = ProfileRepromptInterval(rawValue: repromptRaw) ?? .off
        self.defaultUserID = store.string(forKey: Keys.defaultUserID)
        self.defaultServerID = store.string(forKey: Keys.defaultServerID)
    }
}
