import Foundation

/// Putting this device back to a first-launch state. Log Out is the neighbouring action and stops
/// deliberately short of this: it drops credentials and servers, and keeps preferences, because
/// signing out of a server is no reason to lose a theme. A reset keeps nothing (Sodalite#76).
extension DependencyContainer {

    /// Clears every credential, server and preference on this device.
    ///
    /// `deleteCloudCopy` also removes the copy in iCloud. Without it the reset holds only as long as
    /// sync stays off: the zone still describes the same servers, and re-enabling sync hands them
    /// straight back. With it, there is nothing left to come back from.
    func resetToFactoryState(deleteCloudCopy: Bool) async {
        sessionNote("reset: starting, deleteCloudCopy=\(deleteCloudCopy).")

        // Before the local wipe: deleting the zone needs the engine that clearSession tears down.
        if deleteCloudCopy {
            await cloudSync?.deleteCloudDataAndDisable()
        }

        // Servers, tokens, profiles, passwords, Seerr, and cloud sync off on this device.
        try? clearSession()
        // clearSession scrubs session state; a reset owes nothing to anything. The Guardian PIN, its
        // throttle, the remembered live routes and whatever a later key adds all sit in the same
        // keychain service, so take the service rather than a list that would fall behind.
        try? keychainService.deleteAll()
        SharedSessionMirror.clearAll()

        // Preferences live in two places at once. The domain is what the next launch reads.
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        // The app group is its own domain: the TopShelf extension reads the accent out of it.
        UserDefaults(suiteName: Self.appGroupSuiteName)?
            .removePersistentDomain(forName: Self.appGroupSuiteName)

        // And the objects already in memory are what this session reads. They parsed their values at
        // launch and persist on write, so a wiped domain alone would leave the app wearing the old
        // theme until it is relaunched, and the next edit of any one setting would write a stale
        // neighbour back out.
        if let factory = SettingsStores.factoryDefaults() {
            for key in CloudSyncStoreKey.allCases {
                applySettingsPayload(collectSettingsPayload(key, stamp: .now, from: factory))
            }
        } else {
            sessionNote("reset: no scratch suite for the factory stores, preferences land on defaults at the next launch.")
        }

        FilterCache.shared.clearAll()
        ImageCache.shared.clear()

        sessionNote("reset: done.")
    }

    /// Shared with the TopShelf extension; see TopShelfCachePolicy.appGroup.
    static var appGroupSuiteName: String { "group.de.superuser404.Sodalite" }
}
