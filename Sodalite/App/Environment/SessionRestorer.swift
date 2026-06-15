import Foundation
import os.log

private let restoreLogger = Logger(subsystem: "de.superuser404.Sodalite", category: "tvUser")

/// How AppRouter should route after the launch-time session restore.
/// Produced by `SessionRestorer.restore()`; AppRouter maps it onto
/// AppState + the launchPickerServer state it owns, then runs the
/// Seerr sync for the cases that want one.
enum RestoreOutcome {
    /// A session restored end-to-end: enter the app as `user`. The
    /// user is keychain-bootstrapped (policy: nil), so the caller
    /// kicks the /Users/Me policy refresh after flipping AppState.
    /// Always followed by a Seerr sync.
    case authenticated(server: JellyfinServer, user: JellyfinUser)
    /// Land in the launch profile picker for `server`. `syncSeerr`
    /// distinguishes the full-restore multi-profile route (Seerr
    /// restore is independent of which Jellyfin profile ends up
    /// active and should be ready by the time the user taps a
    /// profile) from the repair / missing-user routes (no session
    /// worth syncing against).
    case picker(server: JellyfinServer, syncSeerr: Bool)
    /// Nothing restorable anywhere: AppRouter leaves its state
    /// untouched and falls through to ServerDiscoveryView.
    case discovery
}

/// Launch-time session-restore policy, extracted from AppRouter so
/// the keychain pointer repair, default-server promotion, pre-0.3.0
/// remembered-user migration, image-tag re-stamping, and the
/// multi-profile launch routing decision live next to the session
/// store (DependencyContainer) instead of inside a view.
///
/// `restore()` is synchronous: every step is keychain- and
/// preference-backed. The async parts of the launch sequence (the
/// tvOS user-context resolution that must run first, the Seerr sync
/// that follows) stay in AppRouter, which owns the AppState
/// mutations their ordering depends on.
@MainActor
struct SessionRestorer {
    let dependencies: DependencyContainer

    func restore() -> RestoreOutcome {
        // Determine whether a tvOS mapping is currently in effect.
        // When one is, both the defaultServerID promotion and the
        // shouldUseDefault launch-behavior branch are suppressed so the
        // tvOS system identity is not clobbered by the user's pinned
        // default server or default profile.
        let hasTVMapping: Bool = {
            guard let tvUserID = TVUserContext.currentUserID else { return false }
            return dependencies.tvProfileMappings.mapping(for: tvUserID) != nil
        }()

        // Promote the user's default server (if set and still known)
        // before restoreSession runs. Lets the user pin which server
        // the app cold-launches into, regardless of which one was last
        // active. No-op when defaultServerID is nil or no longer
        // resolves (e.g. server was removed). Skipped when the default
        // already equals the current pointer, or when a tvOS mapping
        // is in effect (the mapping's server takes precedence).
        if !hasTVMapping,
           let defaultID = dependencies.authPreferences.defaultServerID,
           dependencies.listKnownServers().contains(where: { $0.id == defaultID }),
           (try? dependencies.keychainService.loadString(for: KeychainKeys.activeServerID)) != defaultID {
            try? dependencies.keychainService.save(defaultID, for: KeychainKeys.activeServerID)
        }

        let didRestore = dependencies.restoreSession()
        restoreLogger.notice("SessionRestorer.restore: dependencies.restoreSession() returned \(didRestore, privacy: .public). knownServers=\(dependencies.listKnownServers().map { $0.id }.joined(separator: ","), privacy: .public) activeServer=\(dependencies.activeServer?.id ?? "nil", privacy: .public)")

        if !didRestore {
            // Session couldn't be restored (missing token, unresolved
            // pointer, etc.). Don't early-exit to ServerDiscoveryView
            // if we still know about a server: land in its profile
            // picker so the user can re-pick a remembered profile or
            // add a new one, without losing every other server's
            // saved state.
            let target: JellyfinServer?
            if let server = dependencies.activeServer {
                target = server
            } else if let first = dependencies.listKnownServers().first {
                // Repair: activeServerID is missing or no longer
                // resolves, but knownServers has at least one entry.
                // Promote the most recently added server to active by
                // writing only the pointer (no switchServer here, that
                // would clear JellyfinClient.accessToken and SharedSession
                // Mirror for a target we cannot fully restore in this
                // pass). Land in the profile picker for the recovered
                // server; the next launch's normal restoreSession path
                // resolves token + user from there.
                try? dependencies.keychainService.save(first.id, for: KeychainKeys.activeServerID)
                target = first
            } else {
                target = nil
            }

            guard let target else { return .discovery }
            // Point the client at the known host so the picker's
            // avatar fetches + any subsequent LoginView flow hit
            // the right server. We can't recover the access token
            // here, but the host URL is enough to bootstrap the
            // picker.
            dependencies.jellyfinClient.baseURL = target.url
            return .picker(server: target, syncSeerr: false)
        }

        // restoreSession succeeded, so activeServer must resolve and
        // the access token is in place. The guard below is defensive.
        guard let server = dependencies.activeServer else { return .discovery }

        guard let userID = try? dependencies.keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)),
              let userName = try? dependencies.keychainService.loadString(for: KeychainKeys.activeUserName)
        else {
            // We have a server + token but lost the active-user
            // globals. Don't clearSession (that would nuke every
            // server's per-server state across the install). Land in
            // the picker for this server, the user can re-pick a
            // remembered profile or add a new one.
            return .picker(server: server, syncSeerr: false)
        }

        // primaryImageTag is optional in the keychain, users without
        // a custom avatar never had one persisted. Missing = initials.
        // Fallback path covers JellySeeTV migrations whose last login
        // pre-dated the dedicated activeUserImageTag entry: the
        // RememberedUser blob still carries the tag, so we can lift
        // it from there and re-stamp the canonical key so subsequent
        // restores find it directly.
        let imageTag: String? = {
            if let direct = try? dependencies.keychainService.loadString(for: KeychainKeys.activeUserImageTag) {
                return direct
            }
            guard let fromRemembered = dependencies.listRememberedUsers(serverID: server.id)
                .first(where: { $0.id == userID })?
                .imageTag, !fromRemembered.isEmpty
            else { return nil }
            try? dependencies.keychainService.save(fromRemembered, for: KeychainKeys.activeUserImageTag)
            return fromRemembered
        }()
        let restored = JellyfinUser(
            id: userID,
            name: userName,
            serverID: server.id,
            hasPassword: nil,
            primaryImageTag: imageTag,
            policy: nil
        )

        // Migrate pre-0.3.0 sessions into the remembered-profiles
        // list. Legacy installs only persisted the active session,
        // without this, the "Add another profile" flow would show
        // the currently signed-in user in the picker (since no
        // remembered entry existed to filter by).
        if let token = try? dependencies.keychainService.loadString(
            for: KeychainKeys.accessToken(serverID: server.id)
        ), !dependencies.listRememberedUsers(serverID: server.id)
            .contains(where: { $0.id == userID }) {
            try? dependencies.rememberUser(
                RememberedUser(
                    id: userID,
                    serverID: server.id,
                    name: userName,
                    imageTag: imageTag,
                    token: token
                )
            )
        }

        // Multi-profile routing. Four possible outcomes:
        //
        // - .useDefault + defaultUserID points at a remembered
        //   profile → restore that one (switchToUser if it differs
        //   from the last-active one).
        // - .showPicker + remembered profiles exist → arm the
        //   launch picker; don't setAuthenticated yet.
        // - Launch mode says "default" but the default is missing /
        //   was forgotten → fall back to the picker if we have
        //   something to pick from.
        // - Single-profile install or nothing remembered → the
        //   original behavior: restore and auto-enter the app.
        let remembered = dependencies.listRememberedUsers(serverID: server.id)
        let prefs = dependencies.authPreferences

        // Parental-controls cold-start override: if a Guardian-PIN is set
        // and at least one remembered profile is UNPROTECTED (an escape
        // target), always land in the picker, overriding useDefault and
        // the single-profile auto-enter. Otherwise force-quit + relaunch
        // into an auto-restored unprotected profile would bypass the lock.
        // Selecting an unprotected card in the picker is PIN-gated by
        // LaunchProfilePickerView; selecting a protected card is free.
        if dependencies.parentalControlsActive() {
            let hasUnprotected = remembered.contains { user in
                !dependencies.parentalControlsPreferences.isProtected(serverID: server.id, userID: user.id)
            }
            if hasUnprotected {
                return .picker(server: server, syncSeerr: true)
            }
        }

        let shouldUseDefault = !hasTVMapping
            && prefs.launchBehavior == .useDefault
            && prefs.defaultUserID.flatMap { id in remembered.first { $0.id == id } } != nil

        if shouldUseDefault,
           let defaultID = prefs.defaultUserID,
           let target = remembered.first(where: { $0.id == defaultID }) {
            if target.id != userID {
                try? dependencies.switchToUser(target, server: server)
            }
            let user = JellyfinUser(
                id: target.id,
                name: target.name,
                serverID: server.id,
                hasPassword: nil,
                primaryImageTag: target.imageTag,
                policy: nil
            )
            return .authenticated(server: server, user: user)
        } else if remembered.count > 1 {
            return .picker(server: server, syncSeerr: true)
        } else {
            // Single-profile install (or nothing remembered yet).
            // Enter the app directly, no point showing a picker
            // with one card on it.
            return .authenticated(server: server, user: restored)
        }
    }
}
