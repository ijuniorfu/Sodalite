import Foundation

/// Records, per server id, that we already offered to add the second URL after
/// login, so the prompt fires exactly once (at the onboarding/add moment) and
/// never nags on later re-auth. Mirrors the ServerRouteStore per-id UserDefaults
/// pattern.
enum DualURLPromptLatch {
    private static func key(_ serverID: String) -> String { "dualURLPromptOffered.\(serverID)" }

    static func hasOffered(serverID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(serverID))
    }

    static func markOffered(serverID: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key(serverID))
    }
}
