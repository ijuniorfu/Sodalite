import Foundation
import Observation

/// How the Guardian PIN applies to one profile. The two locked roles are mutually exclusive by
/// construction: a profile that costs a PIN to enter gains nothing from costing one to leave,
/// because whoever got in holds the PIN already.
enum ProfileLockRole: String, CaseIterable, Hashable {
    case open
    case pinToEnter
    case pinToLeave
}

/// Per-profile lock roles keyed by composite serverID:userID, held as two sets so the CloudSync payload stays additive; PIN hash lives in keychain (DependencyContainer) not here; RememberedUser blob untouched.
@Observable
@MainActor
final class ParentalControlsPreferences {

    private enum Keys {
        static let protectedProfileIDs = "parental.protectedProfileIDs"
        static let entryLockedProfileIDs = "parental.entryLockedProfileIDs"
    }

    var protectedProfileIDs: Set<String> {
        didSet {
            store.set(protectedProfileIDs.sorted(), forKey: Keys.protectedProfileIDs)
        }
    }

    var entryLockedProfileIDs: Set<String> {
        didSet {
            store.set(entryLockedProfileIDs.sorted(), forKey: Keys.entryLockedProfileIDs)
        }
    }

    var hasAnyProtectedProfile: Bool { !protectedProfileIDs.isEmpty }

    var hasAnyLockedProfile: Bool { !protectedProfileIDs.isEmpty || !entryLockedProfileIDs.isEmpty }

    static func compositeID(serverID: String, userID: String) -> String {
        "\(serverID):\(userID)"
    }

    func isProtected(serverID: String, userID: String) -> Bool {
        protectedProfileIDs.contains(Self.compositeID(serverID: serverID, userID: userID))
    }

    /// Membership in the leave-lock wins, so a store carrying a key in both sets reads as the
    /// stricter role rather than as something a corruption chose.
    func role(serverID: String, userID: String) -> ProfileLockRole {
        let key = Self.compositeID(serverID: serverID, userID: userID)
        if protectedProfileIDs.contains(key) { return .pinToLeave }
        if entryLockedProfileIDs.contains(key) { return .pinToEnter }
        return .open
    }

    func setRole(_ role: ProfileLockRole, serverID: String, userID: String) {
        let key = Self.compositeID(serverID: serverID, userID: userID)
        protectedProfileIDs.remove(key)
        entryLockedProfileIDs.remove(key)
        switch role {
        case .open:       break
        case .pinToEnter: entryLockedProfileIDs.insert(key)
        case .pinToLeave: protectedProfileIDs.insert(key)
        }
    }

    func setProtected(_ isProtected: Bool, serverID: String, userID: String) {
        let key = Self.compositeID(serverID: serverID, userID: userID)
        if isProtected {
            protectedProfileIDs.insert(key)
        } else {
            protectedProfileIDs.remove(key)
        }
    }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        let stored = store.array(forKey: Keys.protectedProfileIDs) as? [String] ?? []
        self.protectedProfileIDs = Set(stored)
        let storedEntry = store.array(forKey: Keys.entryLockedProfileIDs) as? [String] ?? []
        self.entryLockedProfileIDs = Set(storedEntry)
    }
}
