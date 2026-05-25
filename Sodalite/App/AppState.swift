import Foundation
import Observation

@Observable
final class AppState {
    var isAuthenticated = false
    var activeServer: JellyfinServer?
    var activeUser: JellyfinUser?
    /// Starts as `true` so the brand splash covers the very first
    /// frame, otherwise the underlying view (whichever it is)
    /// flashes for a frame before the AppRouter task can flip it.
    var isLoading = true

    var activeSeerrServer: SeerrServer?
    var activeSeerrUser: SeerrUser?

    /// Set by `onOpenURL` whenever a `sodalite://item/{id}` link
    /// arrives, typically from the TopShelf extension. Cleared
    /// after the AppRouter has fetched + presented the item, so a
    /// repeated tap on the same shelf cell still re-fires.
    var pendingDeepLinkItemID: String?

    /// Flipped by `ContinueWatchingIntent` so AppRouter knows to
    /// fetch the latest Resume item and route to it. Kept separate
    /// from `pendingDeepLinkItemID` because the intent runs before
    /// we know which item to play, AppRouter resolves the queue
    /// and then sets `pendingDeepLinkItemID` itself, reusing the
    /// existing TopShelf navigation path.
    var requestContinueWatching: Bool = false

    /// Monotonic counter the deep-link path increments to ask any
    /// currently presented player to dismiss before the new detail
    /// sheet appears. Without this, a TopShelf tap on a different
    /// item while a paused player is in the background brings the
    /// app forward with the stale player still on top, hiding the
    /// freshly presented detail sheet underneath it. Detail views
    /// that drive a `PlayerLauncher` watch this counter and clear
    /// their local `showPlayer` state on change.
    var requestPlayerDismissal: Int = 0

    /// True while a deep-link is in flight (between the URL handler
    /// dismissing the active player and the new detail sheet
    /// presenting). AppRouter overlays a brief loading view so the
    /// user never sees the prior detail view flash before the new
    /// one slides up.
    var isResolvingDeepLink: Bool = false

    /// Number of modal sheets / full-screen covers currently presented.
    /// Counter (not Bool) so nested presentations stay accurate -- e.g.,
    /// a detail sheet that presents a deletion confirmation. Bumped /
    /// decremented by the coordinated-sheet view modifiers in
    /// `Components/ModalCoordinator.swift`. Read by AppRouter to apply
    /// a soft blur to the underlying content while any modal is up.
    var presentedModalCount: Int = 0

    var isAnyModalPresented: Bool { presentedModalCount > 0 }

    var isSeerrConnected: Bool {
        activeSeerrServer != nil && activeSeerrUser != nil
    }

    func setAuthenticated(server: JellyfinServer, user: JellyfinUser) {
        activeServer = server
        activeUser = user
        isAuthenticated = true
    }

    /// Replaces `activeUser.policy` while preserving every other field
    /// (id, name, server, image tag, etc.). Called after a profile
    /// switch or session restore once `getCurrentUser()` returns a
    /// fresh `JellyfinUser` whose `Policy` block reflects the current
    /// server-side rights. Without this, the activeUser is the
    /// keychain-bootstrapped stub with `policy: nil`, and the
    /// permission-gated UI (delete button, future admin surfaces)
    /// stays hidden until a full logout/login cycle.
    func updateActiveUserPolicy(_ policy: JellyfinUser.Policy?) {
        guard let current = activeUser else { return }
        activeUser = JellyfinUser(
            id: current.id,
            name: current.name,
            serverID: current.serverID,
            hasPassword: current.hasPassword,
            primaryImageTag: current.primaryImageTag,
            policy: policy
        )
    }

    func logout() {
        activeServer = nil
        activeUser = nil
        isAuthenticated = false
        activeSeerrServer = nil
        activeSeerrUser = nil
    }

    func setSeerrConnected(server: SeerrServer, user: SeerrUser) {
        activeSeerrServer = server
        activeSeerrUser = user
    }

    func disconnectSeerr() {
        activeSeerrServer = nil
        activeSeerrUser = nil
    }
}
