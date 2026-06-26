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
    /// Posted by CatalogDetailView after a Seerr request so CatalogView refreshes loaded request lists, else a new request doesn't appear until restart.
    static let seerrRequestDidSubmit = Notification.Name("seerrRequestDidSubmit")
    /// Posted when a detail that hid the tab bar (`.toolbar(.hidden, for: .tabBar)`) disappears. tvOS re-templates the re-shown bar's icons to default gray, dropping the accent tint; TabRootView re-asserts the icon appearance on this signal.
    static let tabBarNeedsRetint = Notification.Name("tabBarNeedsRetint")
}

/// userInfo keys for `.playbackProgressDidChange`.
enum PlaybackProgressKey {
    /// `String` item id whose playback position changed.
    static let itemID = "itemID"
    /// `Int64` position (in Jellyfin ticks) the player stopped at.
    static let positionTicks = "positionTicks"
}
