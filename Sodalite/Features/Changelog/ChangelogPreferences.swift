import Foundation

/// Decides whether WhatsNewView fires after the splash via lastSeenVersion upgrade detection: same version → no; newer w/ non-empty stamp → show once; empty stamp + fresh install → silent stamp; empty stamp + existing user → show (pre-Changelog upgrade).
/// `isExistingUser` discriminator passed by AppRouter from appState.isAuthenticated, separates "first install" from "upgrade from pre-Changelog build".
enum ChangelogPreferences {
    private static let storeKey = "changelog.lastSeenVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: storeKey) ?? ""
    }

    /// Should WhatsNewView fire on this launch?
    /// - Parameter isExistingUser: authenticated when checked; discriminates empty `lastSeenVersion` as "first install" vs "pre-Changelog upgrade".
    static func shouldShowOnLaunch(isExistingUser: Bool) -> Bool {
        let last = lastSeenVersion
        let current = currentVersion
        guard !current.isEmpty else { return false }
        if last == current { return false }
        if last.isEmpty {
            // No prior stamp: show only for upgraders, not fresh installs.
            return isExistingUser
        }
        return true
    }

    /// Stamps the current version so the modal won't show again until another upgrade.
    static func markCurrentSeen() {
        UserDefaults.standard.set(currentVersion, forKey: storeKey)
    }

    /// First-install bootstrap: stamp current version without showing the modal. Idempotent.
    static func bootstrapIfNeeded() {
        guard lastSeenVersion.isEmpty else { return }
        markCurrentSeen()
    }

    /// Test/debug only: forget last-seen version so the next launch fires the modal.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}
