import Foundation
import Observation

@Observable
final class AppState {
    /// Single instance (App `@State` + `@Environment` default both resolve here); mirrors DependencyContainer.shared.
    static let shared = AppState()

    var isAuthenticated = false
    var activeServer: JellyfinServer?
    var activeUser: JellyfinUser?
    /// Starts `true` so the splash covers the first frame, else the underlying view flashes before AppRouter flips it.
    var isLoading = true

    var activeSeerrServer: SeerrServer?
    var activeSeerrUser: SeerrUser?

    /// `sodalite://item/{id}` id set by onOpenURL (usually TopShelf); AppRouter clears it after presenting so a repeat tap re-fires. The deep-link signal field.
    var pendingDeepLinkItemID: String?

    /// Flipped by ContinueWatchingIntent; AppRouter fetches the latest Resume item then routes via pendingDeepLinkItemID. Separate because the intent runs before the target item is known.
    var requestContinueWatching: Bool = false

    /// Bumped by DependencyContainer after a server switch; consumers (Home) observe via `.task(id:)` to clear caches + reload. Int (not Date) so back-to-back switches always change the value.
    var serverDidSwitch: Int = 0

    /// Bumped by the deep-link path to dismiss a presented player before the new sheet, else a TopShelf tap brings the app forward with the stale player on top. Detail views driving a PlayerLauncher clear showPlayer on change.
    var requestPlayerDismissal: Int = 0

    /// True while a deep-link is in flight; AppRouter overlays a loading view so the prior detail view doesn't flash.
    var isResolvingDeepLink: Bool = false

    /// True while the fresh-install launch gate is waiting on the first iCloud fetch; SplashView surfaces a status line.
    var isCloudSyncProbing = false

    var isSeerrConnected: Bool {
        activeSeerrServer != nil && activeSeerrUser != nil
    }

    func setAuthenticated(server: JellyfinServer, user: JellyfinUser) {
        activeServer = server
        activeUser = user
        isAuthenticated = true
    }

    /// Replaces activeUser.policy (preserving other fields) after a profile switch/restore once getCurrentUser() returns fresh rights, else the keychain stub's policy: nil keeps permission-gated UI hidden until logout/login.
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

    /// Replaces activeServer with a fresh copy (applies an updated version after a server upgrade). id guard so a racing switch doesn't apply another server's data.
    func updateActiveServer(_ server: JellyfinServer) {
        guard activeServer?.id == server.id else { return }
        activeServer = server
    }

    /// Same id-guarded replace as updateActiveServer, for the Seerr server (URL slot edits).
    func updateActiveSeerrServer(_ server: SeerrServer) {
        guard activeSeerrServer?.id == server.id else { return }
        activeSeerrServer = server
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
