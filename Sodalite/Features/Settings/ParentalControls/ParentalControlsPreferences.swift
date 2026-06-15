import Foundation
import Observation

/// Per-remembered-profile "protected" flags for parental controls.
/// A profile is keyed by the composite "serverID:userID" so the same
/// Jellyfin user on two servers is tracked independently. The Guardian
/// PIN hash itself lives in the keychain (see DependencyContainer), not
/// here: this store holds only the non-sensitive which-profiles-are-kids
/// set. The auth-critical RememberedUser keychain blob is never touched.
@Observable
@MainActor
final class ParentalControlsPreferences {

    private enum Keys {
        static let protectedProfileIDs = "parental.protectedProfileIDs"
    }

    /// Composite "serverID:userID" keys of profiles marked protected.
    var protectedProfileIDs: Set<String> {
        didSet {
            store.set(protectedProfileIDs.sorted(), forKey: Keys.protectedProfileIDs)
        }
    }

    var hasAnyProtectedProfile: Bool { !protectedProfileIDs.isEmpty }

    static func compositeID(serverID: String, userID: String) -> String {
        "\(serverID):\(userID)"
    }

    func isProtected(serverID: String, userID: String) -> Bool {
        protectedProfileIDs.contains(Self.compositeID(serverID: serverID, userID: userID))
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
    }
}
