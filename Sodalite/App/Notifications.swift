import Foundation

/// App-wide notification names, centralised because posters/observers span features (player, detail, auth, catalog).
extension Notification.Name {
    static let homeConfigDidChange = Notification.Name("homeConfigDidChange")
    static let homeFavoritesDidChange = Notification.Name("homeFavoritesDidChange")
    static let homePlayedDidChange = Notification.Name("homePlayedDidChange")
    /// Posted by PlayerViewModel after a playback-stop report so HomeView/detail refresh Continue Watching / Next Up. Carries PlaybackProgressKey.itemID (the EPISODE for series) + positionTicks; detail views patch that item's in-memory userData directly (authoritative, race-free, vs re-fetch + stale ETag, issue #24).
    static let playbackProgressDidChange = Notification.Name("playbackProgressDidChange")
    /// Posted by detail views after a deletion so HomeView reloads and the item disappears immediately.
    static let homeItemDidDelete = Notification.Name("homeItemDidDelete")
    /// Fires after LoginView completes; ProfileSettingsView pops its "Add another profile" branch, else the success screen hangs (already authenticated, AppRouter doesn't tear down TabRootView).
    static let loginDidComplete = Notification.Name("loginDidComplete")
    /// Posted whenever the set of Seerr requests changed (submitted, or removed from the catalog detail / by a cascading deletion) so CatalogView refreshes loaded request lists. Without it the list keeps its stale rows until an app restart.
    static let seerrRequestsDidChange = Notification.Name("seerrRequestsDidChange")

    /// Posted after an admin approves/declines/deletes a request or the admin queue reloads its counts,
    /// so the pending-requests monitor recomputes the Catalog tab badge.
    static let seerrPendingRequestsShouldRefresh = Notification.Name("seerrPendingRequestsShouldRefresh")

    /// Posted by CloudSyncService after remote changes were applied locally, so
    /// server lists, pickers, and settings screens refresh.
    static let cloudSyncDidApplyChanges = Notification.Name("cloudSyncDidApplyChanges")

    /// Posted by DependencyContainer after the route resolver moved the active
    /// session to the other URL slot (internal <-> external).
    static let serverRouteDidChange = Notification.Name("serverRouteDidChange")

    static let playerModalPresenceDidChange =
        Notification.Name("playerModalPresenceDidChange")

    /// Posted by PlayerViewModel whenever the running session switches to another item (auto-advance,
    /// play queue, season picker). Detail views follow it so leaving the player lands on the episode
    /// that was watched last, not the one that was started. Carries PlayerItemSwitchKey.item.
    static let playerDidSwitchItem = Notification.Name("playerDidSwitchItem")
}

/// userInfo keys for `.playerDidSwitchItem`.
enum PlayerItemSwitchKey {
    /// The `JellyfinItem` the session switched to.
    static let item = "item"
}

/// userInfo keys for `.playbackProgressDidChange`.
enum PlaybackProgressKey {
    /// `String` item id whose playback position changed.
    static let itemID = "itemID"
    /// `Int64` position (in Jellyfin ticks) the player stopped at.
    static let positionTicks = "positionTicks"
}
