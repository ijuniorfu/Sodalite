import Foundation
import Observation

/// Per-profile protected flags keyed by composite serverID:userID; PIN hash lives in keychain (DependencyContainer) not here; RememberedUser blob untouched.
@Observable
@MainActor
final class ParentalControlsPreferences {

    private enum Keys {
        static let protectedProfileIDs = "parental.protectedProfileIDs"
    }

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
