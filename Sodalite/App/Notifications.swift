import Foundation

/// App-wide notification names. Centralised here because the posters
/// and observers span features (player, detail views, auth flows,
/// catalog); these used to live in HomeCustomizeView.swift, which made
/// them easy to miss.
extension Notification.Name {
    static let homeConfigDidChange = Notification.Name("homeConfigDidChange")
    static let homeFavoritesDidChange = Notification.Name("homeFavoritesDidChange")
    static let homePlayedDidChange = Notification.Name("homePlayedDidChange")
    /// Posted by PlayerViewModel after a successful playback-stop
    /// report. Lets HomeView (and any other view that cares) refresh
    /// Continue Watching / Next Up so the user sees their new
    /// progress as soon as they're back.
    static let playbackProgressDidChange = Notification.Name("playbackProgressDidChange")
    /// Posted by the detail views after a successful deletion. Lets
    /// HomeView reload so the deleted item disappears from the rows
    /// immediately instead of lingering until the next stale refresh.
    static let homeItemDidDelete = Notification.Name("homeItemDidDelete")
    /// Fires after LoginView completes (password or Quick Connect).
    /// ProfileSettingsView listens so it can pop its "Add another
    /// profile" navigation branch, without it, the login success
    /// screen hangs because the user was already authenticated
    /// before and AppRouter doesn't tear down TabRootView.
    static let loginDidComplete = Notification.Name("loginDidComplete")
    /// Posted by CatalogDetailView after a successful Seerr request.
    /// CatalogView listens and refreshes whichever request lists are
    /// already loaded; without this, My Requests and the admin queue
    /// only reloaded when empty, so a new request didn't appear until
    /// app restart.
    static let seerrRequestDidSubmit = Notification.Name("seerrRequestDidSubmit")
}
