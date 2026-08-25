import Foundation

/// Whether the app wants its Top Shelf row rendered at all, mirrored into the shared container
/// because the extension cannot read the app's own preferences.
///
/// It exists because of an Apple bug: the Top Shelf extension does not run in the active tvOS
/// user's context, so on a box with several users it serves the Default user's Continue Watching
/// to everyone. Measured on tvOS 26.6 against both user-management entitlement values, and
/// reported independently by Firecore for Infuse ("the top shelf will currently show items for
/// the Apple TV's 'Default' user"). Nothing in the app can select the right session: every API
/// that named a user was deprecated in tvOS 16. So the honest fix is a switch.
///
/// `nonisolated` for the same reason as `TopShelfAccent`: both targets compile this file.
enum TopShelfEnabled {
    nonisolated static let defaultsKey = "topshelf.enabled"

    /// On, matching the shipped behaviour and every single-user Apple TV, which is most of them.
    /// Absent means an install that predates the switch, not an install that opted out.
    nonisolated static func read() -> Bool {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup),
              let stored = defaults.object(forKey: defaultsKey) as? NSNumber
        else { return true }
        return stored.boolValue
    }

    nonisolated static func write(_ enabled: Bool) {
        guard let defaults = UserDefaults(suiteName: TopShelfCachePolicy.appGroup) else { return }
        defaults.set(NSNumber(value: enabled), forKey: defaultsKey)
    }
}
