import Foundation

/// Decides whether the WhatsNewView modal fires after the splash.
///
/// Logic:
/// - First install ever: `lastSeenVersion` is empty. Mark the
///   current version as seen and DON'T show the modal — a brand-new
///   user just wants the app, not a pop-up about features they've
///   never not had.
/// - Same version as last launch: `lastSeenVersion == current`.
///   Don't show.
/// - Updated to a newer version: `lastSeenVersion != current`.
///   Show the modal once, then mark seen.
enum ChangelogPreferences {
    private static let storeKey = "changelog.lastSeenVersion"

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private static var lastSeenVersion: String {
        UserDefaults.standard.string(forKey: storeKey) ?? ""
    }

    /// Should the WhatsNewView fire on this launch? Returns false on
    /// first install (so we don't pester new users) and on launches
    /// where the version hasn't changed since the previous run.
    static func shouldShowOnLaunch() -> Bool {
        let last = lastSeenVersion
        let current = currentVersion
        guard !last.isEmpty else { return false }
        guard !current.isEmpty else { return false }
        return last != current
    }

    /// Called from the modal's dismiss action and from the first-
    /// install code path. Stamps the current version so we won't
    /// show again until another upgrade lands.
    static func markCurrentSeen() {
        UserDefaults.standard.set(currentVersion, forKey: storeKey)
    }

    /// Bootstrap on first install — flips lastSeenVersion to current
    /// without showing the modal. Idempotent: a re-call after an
    /// upgrade does nothing because lastSeenVersion is already set.
    static func bootstrapIfNeeded() {
        guard lastSeenVersion.isEmpty else { return }
        markCurrentSeen()
    }

    /// Test/debug only: forget the last-seen version so the next
    /// launch fires the modal.
    static func forget() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }
}
