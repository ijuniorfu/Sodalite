import Foundation
import os.log

private let restoreLogger = Logger(subsystem: "de.superuser404.Sodalite", category: "tvUser")

/// Routing verdict from SessionRestorer.restore(); AppRouter maps it onto AppState + launchPickerServer and runs the Seerr sync where wanted.
enum RestoreOutcome {
    /// Restored end-to-end: enter as `user` (keychain-bootstrapped, policy: nil, so caller kicks the /Users/Me refresh). Always followed by a Seerr sync.
    case authenticated(server: JellyfinServer, user: JellyfinUser)
    /// Land in the launch picker. `syncSeerr` true for the full-restore multi-profile route (Seerr is profile-independent and should be ready), false for repair / missing-user routes.
    case picker(server: JellyfinServer, syncSeerr: Bool)
    /// Nothing restorable: AppRouter falls through to ServerDiscoveryView.
    case discovery
}

/// Launch-time restore policy (pointer repair, default-server promotion, pre-0.3.0 user migration, image-tag re-stamping, multi-profile routing), extracted from AppRouter to sit next to the session store. `restore()` is synchronous (all keychain/preference-backed); the async tvOS-context resolve + Seerr sync stay in AppRouter, which owns their ordering-dependent AppState mutations.
@MainActor
struct SessionRestorer {
    let dependencies: DependencyContainer

    func restore() -> RestoreOutcome {
        // When a tvOS mapping is in effect, suppress defaultServerID promotion + the shouldUseDefault branch so the system identity isn't clobbered by user-pinned defaults.
        let hasTVMapping: Bool = {
            guard let tvUserID = TVUserContext.currentUserID else { return false }
            return dependencies.tvProfileMappings.mapping(for: tvUserID) != nil
        }()

        // Promote the user's pinned default server before restoreSession. No-op when nil/unresolved or already the current pointer; skipped under a tvOS mapping (mapping wins).
        if !hasTVMapping,
           let defaultID = dependencies.authPreferences.defaultServerID,
           dependencies.listKnownServers().contains(where: { $0.id == defaultID }),
           (try? dependencies.keychainService.loadString(for: KeychainKeys.activeServerID)) != defaultID {
            try? dependencies.keychainService.save(defaultID, for: KeychainKeys.activeServerID)
        }

        let didRestore = dependencies.restoreSession()
        restoreLogger.notice("SessionRestorer.restore: dependencies.restoreSession() returned \(didRestore, privacy: .public). knownServers=\(dependencies.listKnownServers().map { $0.id }.joined(separator: ","), privacy: .public) activeServer=\(dependencies.activeServer?.id ?? "nil", privacy: .public)")

        if !didRestore {
            // Restore failed (missing token, unresolved pointer). Don't drop to discovery if we still know a server: land in its picker so the user keeps every other server's saved state.
            let target: JellyfinServer?
            if let server = dependencies.activeServer {
                target = server
            } else if let first = dependencies.listKnownServers().first {
                // Repair: pointer missing/unresolved but knownServers non-empty. Promote by writing only the pointer (NOT switchServer, which would clear token + SharedSessionMirror for a target we can't fully restore this pass); next launch resolves token + user.
                try? dependencies.keychainService.save(first.id, for: KeychainKeys.activeServerID)
                target = first
            } else {
                target = nil
            }

            guard let target else { return .discovery }
            // Point the client at the known host so the picker's avatar fetches + any LoginView hit the right server (token unrecoverable here, host URL is enough).
            dependencies.jellyfinClient.baseURL = target.url
            return .picker(server: target, syncSeerr: false)
        }

        // restoreSession succeeded so activeServer + token are in place; this guard is defensive.
        guard let server = dependencies.activeServer else { return .discovery }

        guard let userID = try? dependencies.keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)),
              let userName = try? dependencies.keychainService.loadString(for: KeychainKeys.activeUserName)
        else {
            // Server + token but lost the active-user globals. Don't clearSession (nukes every server's per-server state); land in this server's picker.
            return .picker(server: server, syncSeerr: false)
        }

        // primaryImageTag is optional (no custom avatar = initials). Fallback covers JellySeeTV migrations predating the activeUserImageTag entry: lift the tag from the RememberedUser blob and re-stamp the canonical key.
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

        // Migrate pre-0.3.0 sessions into remembered-profiles (legacy installs only persisted the active session, so "Add another profile" would show the current user with no entry to filter by).
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

        // Multi-profile routing: useDefault+valid default → restore it (switchToUser if it differs); showPicker or default missing → picker; single-profile/nothing remembered → auto-enter.
        let remembered = dependencies.listRememberedUsers(serverID: server.id)
        let prefs = dependencies.authPreferences

        // SECURITY (parental controls) cold-start override: with a PIN set and any UNPROTECTED profile, force the picker (overriding useDefault + auto-enter), else force-quit+relaunch auto-restores an unprotected profile and bypasses the lock. Picker PIN-gates unprotected cards (LaunchProfilePickerView); protected cards are free.
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
            // Single-profile (or nothing remembered): enter directly, no one-card picker.
            return .authenticated(server: server, user: restored)
        }
    }
}
