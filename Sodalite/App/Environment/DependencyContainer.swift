import Foundation
import AetherEngine

@MainActor
@Observable
final class DependencyContainer {
    @MainActor static let playerEngine: AetherEngine = try! AetherEngine()
    let keychainService: KeychainServiceProtocol
    let httpClient: HTTPClientProtocol
    let jellyfinClient: JellyfinClient
    let serverDiscoveryService: ServerDiscoveryServiceProtocol
    let jellyfinAuthService: JellyfinAuthServiceProtocol
    let jellyfinLibraryService: JellyfinLibraryServiceProtocol
    let jellyfinItemService: JellyfinItemServiceProtocol
    let jellyfinSearchService: JellyfinSearchServiceProtocol
    let jellyfinImageService: JellyfinImageService
    let jellyfinPlaybackService: JellyfinPlaybackServiceProtocol
    let playbackPreferences: PlaybackPreferences
    let storeKitService: StoreKitServiceProtocol
    let appearancePreferences: AppearancePreferences
    let authPreferences: AuthPreferences

    let seerrClient: SeerrClient
    let seerrServerDiscoveryService: SeerrServerDiscoveryServiceProtocol
    let seerrAuthService: SeerrAuthServiceProtocol
    let seerrDiscoverService: SeerrDiscoverServiceProtocol
    let seerrMediaService: SeerrMediaServiceProtocol
    let seerrRequestService: SeerrRequestServiceProtocol
    let seerrServiceConfigService: SeerrServiceConfigServiceProtocol
    let seerrSearchService: SeerrSearchServiceProtocol

    /// File-deletion service that fronts Jellyfin and Seerr. Used by
    /// MovieDetailView and SeriesDetailView when the active user has
    /// content-deletion rights (see JellyfinUser.canDeleteContent).
    let mediaDeletionService: any MediaDeletionServiceProtocol

    /// Back-reference to AppState so switchServer / removeServer can
    /// bump the serverDidSwitch signal without threading AppState
    /// through every call site. Weak to avoid a retain cycle
    /// (AppState does not own DependencyContainer).
    weak var appState: AppState?

    init(
        keychainService: KeychainServiceProtocol = KeychainService(),
        httpClient: HTTPClientProtocol = HTTPClient()
    ) {
        // First-launch hook: copy credentials over from the old
        // JellySeeTV install (if any) so existing testers aren't
        // sent back to the login screen post-rename. Idempotent,
        // see KeychainMigrator. Has to run BEFORE keychainService
        // is touched.
        KeychainMigrator.migrateIfNeeded()

        self.keychainService = keychainService
        self.httpClient = httpClient
        self.jellyfinClient = JellyfinClient(httpClient: httpClient)
        self.serverDiscoveryService = ServerDiscoveryService(httpClient: httpClient)
        self.jellyfinAuthService = JellyfinAuthService(client: jellyfinClient)
        self.jellyfinLibraryService = JellyfinLibraryService(client: jellyfinClient)
        self.jellyfinItemService = JellyfinItemService(client: jellyfinClient)
        self.jellyfinSearchService = JellyfinSearchService(client: jellyfinClient)
        self.jellyfinImageService = JellyfinImageService(
            baseURLProvider: { [weak jellyfinClient] in
                jellyfinClient?.baseURL
            },
            accessTokenProvider: { [weak jellyfinClient] in
                jellyfinClient?.accessToken
            }
        )
        self.jellyfinPlaybackService = JellyfinPlaybackService(client: jellyfinClient)
        self.playbackPreferences = PlaybackPreferences()
        self.storeKitService = StoreKitService()
        self.appearancePreferences = AppearancePreferences()
        self.authPreferences = AuthPreferences()

        self.seerrClient = SeerrClient(httpClient: httpClient)
        self.seerrServerDiscoveryService = SeerrServerDiscoveryService(httpClient: httpClient)
        self.seerrAuthService = SeerrAuthService(client: seerrClient)
        self.seerrDiscoverService = SeerrDiscoverService(client: seerrClient)
        self.seerrMediaService = SeerrMediaService(client: seerrClient)
        self.seerrRequestService = SeerrRequestService(client: seerrClient)
        self.seerrServiceConfigService = SeerrServiceConfigService(client: seerrClient)
        self.seerrSearchService = SeerrSearchService(client: seerrClient)

        self.mediaDeletionService = MediaDeletionService(
            jellyfinItems: self.jellyfinItemService,
            seerrMedia: self.seerrMediaService,
            isSeerrAuthenticated: { [weak seerrClient] in
                // sessionCookie is non-nil after a successful Seerr
                // login and cleared on logout / session restore failure.
                // Pre-flight check; the live value is read on every
                // invocation (no caching).
                seerrClient?.sessionCookie != nil
            }
        )
    }

    /// Probes /Users/Me against the active server. Returns the
    /// JellyfinUser on success. On 401, drops the remembered entry
    /// for that (server, user) pair and the access token slot, and
    /// returns nil so the caller can route to the profile picker.
    /// Throws on transport errors (caller should keep the previous
    /// server active and surface a toast / handle the failure).
    @MainActor
    func probeActiveUser() async throws -> JellyfinUser? {
        guard let server = activeServer,
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        else { return nil }

        do {
            let user = try await jellyfinAuthService.getCurrentUser()
            return user
        } catch APIError.unauthorized {
            try? keychainService.delete(for: KeychainKeys.accessToken(serverID: server.id))
            try? keychainService.delete(for: KeychainKeys.userID(serverID: server.id))

            // Drop the remembered user too; their token is dead.
            var users = listRememberedUsers(serverID: server.id)
            users.removeAll { $0.id == userID }
            if let data = try? JSONEncoder().encode(users) {
                try? keychainService.save(data, for: KeychainKeys.rememberedUsers(serverID: server.id))
            }
            jellyfinClient.accessToken = nil
            SharedSessionMirror.clear()
            forgetRememberedSeerr(
                forJellyfinUserID: userID,
                jellyfinServerID: server.id
            )
            return nil
        }
    }

    /// `try?` is intentional here: a missing or unreadable Keychain entry
    /// (fresh install, wiped storage, corrupted item) means there's no session
    /// to restore, the app falls back to the login screen. There's no recovery
    /// path that would benefit from inspecting the underlying error.
    func restoreSession() -> Bool {
        guard let server = activeServer,
              let token = try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))
        else {
            return false
        }

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        // Re-project into the shared keychain on every cold launch
        // so the TopShelf extension stays in lockstep even if a
        // previous app version didn't write the mirror, or the user
        // wiped just the shelf's bucket somehow.
        if let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)) {
            SharedSessionMirror.write(serverURL: server.url, userID: userID, accessToken: token)
        }
        return true
    }

    func saveSession(
        server: JellyfinServer,
        user: JellyfinUser,
        token: String,
        password: String? = nil
    ) throws {
        try addServer(server)
        try keychainService.save(server.id, for: KeychainKeys.activeServerID)
        try keychainService.save(token, for: KeychainKeys.accessToken(serverID: server.id))
        try keychainService.save(user.id, for: KeychainKeys.userID(serverID: server.id))
        try keychainService.save(user.name, for: "activeUserName")

        // Persist the avatar image tag so Settings can render the
        // profile picture across cold launches instead of falling
        // back to initials. If the user has no custom avatar, clear
        // any previously-stored tag so a removed image doesn't
        // linger and 404 on every restore.
        if let tag = user.primaryImageTag, !tag.isEmpty {
            try keychainService.save(tag, for: "activeUserImageTag")
        } else {
            try? keychainService.delete(for: "activeUserImageTag")
        }

        if let password, !password.isEmpty {
            try keychainService.save(password, for: KeychainKeys.jellyfinPassword(serverID: server.id))
        }

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        SharedSessionMirror.write(serverURL: server.url, userID: user.id, accessToken: token)

        // Add/update this user in the remembered-profiles list for
        // the server so the user can later switch to any previous
        // profile without re-authenticating.
        try rememberUser(
            RememberedUser(
                id: user.id,
                serverID: server.id,
                name: user.name,
                imageTag: user.primaryImageTag,
                token: token
            )
        )
    }

    // MARK: - Known Servers

    /// All servers the user has ever logged into and not removed.
    /// Front of the list is the most recently added or upserted
    /// entry. Empty list on a fresh install or after the user has
    /// removed every server.
    func listKnownServers() -> [JellyfinServer] {
        guard let data = try? keychainService.loadData(for: KeychainKeys.knownServers)
        else { return [] }
        return (try? JSONDecoder().decode([JellyfinServer].self, from: data)) ?? []
    }

    /// Upsert by `JellyfinServer.id`. Existing entries with the same
    /// id are removed and the new value is prepended, so re-running
    /// the add flow against a server whose URL has changed updates
    /// the URL in place and floats the entry to the top of pickers.
    func addServer(_ server: JellyfinServer) throws {
        var servers = listKnownServers().filter { $0.id != server.id }
        servers.insert(server, at: 0)
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
    }

    /// Resolves the active-server pointer against the known-servers
    /// list. Returns nil if either is missing (fresh install or a
    /// pointer that no longer resolves; the latter is repaired in
    /// AppRouter.restoreSession).
    var activeServer: JellyfinServer? {
        guard let id = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        else { return nil }
        return listKnownServers().first(where: { $0.id == id })
    }

    enum ServerSwitchError: Error {
        /// The requested server id was not in knownServers.
        case unknown
        /// The target server has no stored access token. The caller
        /// must show the profile picker (or LoginView if there are
        /// no remembered users either).
        case missingToken
    }

    /// Switch the active server to `serverID`. Sets the active-server
    /// pointer, loads the cached access token, reconfigures the
    /// Jellyfin HTTP client, rewrites SharedSessionMirror so TopShelf
    /// follows along, and restores the Seerr session for the most
    /// recently used remembered user on that server. The caller
    /// observes the resulting state via the appState.serverDidSwitch
    /// signal (incrementing token) added in a later task.
    ///
    /// Throws `ServerSwitchError.unknown` if the id is not in
    /// knownServers, `ServerSwitchError.missingToken` if the server
    /// has no cached access token (caller routes to login).
    func switchServer(to serverID: String) throws {
        guard let server = listKnownServers().first(where: { $0.id == serverID }) else {
            throw ServerSwitchError.unknown
        }

        try keychainService.save(serverID, for: KeychainKeys.activeServerID)

        let loaded: String?
        do {
            loaded = try keychainService.loadString(for: KeychainKeys.accessToken(serverID: serverID))
        } catch {
            loaded = nil
        }

        guard let token = loaded else {
            jellyfinClient.baseURL = server.url
            jellyfinClient.accessToken = nil
            SharedSessionMirror.clear()
            throw ServerSwitchError.missingToken
        }

        let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        if let userID {
            SharedSessionMirror.write(serverURL: server.url, userID: userID, accessToken: token)
        } else {
            SharedSessionMirror.clear()
        }

        // Seerr session is per (server, user); the caller layer
        // (AppRouter / restoreSession) handles the post-switch
        // probe + Seerr restore via the existing restore path. We
        // intentionally do not touch Seerr here so callers can
        // route to a profile picker first when userID is nil.

        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
    }

    /// Remove a server and every piece of state scoped to it. The
    /// per-server access token, password, remembered users, and all
    /// remembered Seerr sessions for users on this server are
    /// deleted. If the removed server was the active one and at
    /// least one other server remains, the most recently added
    /// remaining server is promoted to active (with whatever token
    /// it has cached; AppRouter's restoreSession path handles
    /// expired tokens). If no servers remain, activeServerID is
    /// cleared and SharedSessionMirror is wiped, the next launch
    /// lands in ServerDiscoveryView.
    func removeServer(id serverID: String) throws {
        let allUsers = listRememberedUsers(serverID: serverID)
        for remembered in allUsers {
            forgetRememberedSeerr(
                forJellyfinUserID: remembered.id,
                jellyfinServerID: serverID
            )
        }

        try? keychainService.delete(for: KeychainKeys.accessToken(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.userID(serverID: serverID))
        try? keychainService.delete(for: KeychainKeys.rememberedUsers(serverID: serverID))

        let servers = listKnownServers().filter { $0.id != serverID }
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)

        if authPreferences.defaultServerID == serverID {
            authPreferences.defaultServerID = nil
        }

        let activeID = try? keychainService.loadString(for: KeychainKeys.activeServerID)
        if activeID == serverID {
            if let successor = servers.first {
                try? switchServer(to: successor.id)
            } else {
                try? keychainService.delete(for: KeychainKeys.activeServerID)
                jellyfinClient.baseURL = nil
                jellyfinClient.accessToken = nil
                SharedSessionMirror.clear()
            }
        }

        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
    }

    /// Roll the active-server pointer back to a previous value.
    /// Used when a post-switch probe fails with a transport error
    /// (network down, server unreachable). Resets JellyfinClient
    /// and SharedSessionMirror to the rollback target's cached
    /// state so the rest of the app sees a consistent snapshot of
    /// the previous server.
    func rollbackSwitch(to serverID: String) throws {
        try switchServer(to: serverID)
        // Re-issue the serverDidSwitch signal so observers reload
        // against the rolled-back state. The signal would already
        // fire from switchServer above, but we make the rollback
        // intent explicit so callers reading the signal stream can
        // tell rollbacks apart by count (two bumps in quick succession).
    }

    // MARK: - Remembered Profiles

    /// All profiles for a server whose token we have cached. Sorted
    /// by most-recently-added first so fresh logins float to the top
    /// of pickers.
    func listRememberedUsers(serverID: String) -> [RememberedUser] {
        guard let data = try? keychainService.loadData(
            for: KeychainKeys.rememberedUsers(serverID: serverID)
        ) else { return [] }
        let users = (try? JSONDecoder().decode([RememberedUser].self, from: data)) ?? []
        return users.sorted { $0.addedAt > $1.addedAt }
    }

    /// Upsert, replaces any existing entry with the same user ID so
    /// re-logins refresh the token and avatar tag instead of
    /// stacking duplicates.
    func rememberUser(_ user: RememberedUser) throws {
        var users = listRememberedUsers(serverID: user.serverID)
            .filter { $0.id != user.id }
        users.append(user)
        let data = try JSONEncoder().encode(users)
        try keychainService.save(
            data,
            for: KeychainKeys.rememberedUsers(serverID: user.serverID)
        )
    }

    /// Drop one profile from the remembered list. Called from the
    /// profile-picker's long-press menu. Leaves the active session
    /// alone, the caller decides whether to switch afterwards.
    func forgetUser(id: String, serverID: String) throws {
        let remaining = listRememberedUsers(serverID: serverID)
            .filter { $0.id != id }
        if remaining.isEmpty {
            try? keychainService.delete(
                for: KeychainKeys.rememberedUsers(serverID: serverID)
            )
        } else {
            let data = try JSONEncoder().encode(remaining)
            try keychainService.save(
                data,
                for: KeychainKeys.rememberedUsers(serverID: serverID)
            )
        }
        // Drop the profile-scoped Seerr session too so a forgotten
        // user doesn't leave a dangling Seerr cookie in the keychain.
        forgetRememberedSeerr(forJellyfinUserID: id, jellyfinServerID: serverID)
    }

    /// Swap to an already-remembered profile. Re-uses the cached
    /// token, updates the active-session keychain entries, and
    /// reconfigures the HTTP client. Drops the cached Jellyfin
    /// password (which is keyed per-server, not per-user) so the
    /// Seerr auto-fill doesn't pre-fill the previous user's
    /// password onto the new user.
    func switchToUser(_ remembered: RememberedUser, server: JellyfinServer) throws {
        try addServer(server)
        try keychainService.save(server.id, for: KeychainKeys.activeServerID)
        try keychainService.save(
            remembered.token,
            for: KeychainKeys.accessToken(serverID: server.id)
        )
        try keychainService.save(
            remembered.id,
            for: KeychainKeys.userID(serverID: server.id)
        )
        try keychainService.save(remembered.name, for: "activeUserName")

        if let tag = remembered.imageTag, !tag.isEmpty {
            try keychainService.save(tag, for: "activeUserImageTag")
        } else {
            try? keychainService.delete(for: "activeUserImageTag")
        }

        try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: server.id))

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = remembered.token

        SharedSessionMirror.write(
            serverURL: server.url,
            userID: remembered.id,
            accessToken: remembered.token
        )

        // Seerr is handled separately by the caller via
        // restoreSeerrSession(forJellyfinUserID:jellyfinServerID:).
        // Keeping it out of switchToUser means a profile that has
        // its own remembered Seerr session picks it back up on
        // switch, while a profile with no Seerr history correctly
        // lands on the "set up Seerr" empty state.
    }

    func loadJellyfinPassword() -> String? {
        guard let server = activeJellyfinServerID else { return nil }
        return try? keychainService.loadString(for: KeychainKeys.jellyfinPassword(serverID: server))
    }

    private var activeJellyfinServerID: String? {
        try? keychainService.loadString(for: KeychainKeys.activeServerID)
    }

    func clearSession() throws {
        // Full logout: scrub every known server's per-server keychain
        // entries (tokens, passwords, remembered users, Seerr cookies).
        // Then clear the multi-server pointers + the global active-user
        // keys + the JellyfinClient state + SharedSessionMirror.
        for known in listKnownServers() {
            for remembered in listRememberedUsers(serverID: known.id) {
                forgetRememberedSeerr(
                    forJellyfinUserID: remembered.id,
                    jellyfinServerID: known.id
                )
            }
            try? keychainService.delete(for: KeychainKeys.accessToken(serverID: known.id))
            try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: known.id))
            try? keychainService.delete(for: KeychainKeys.userID(serverID: known.id))
            try? keychainService.delete(for: KeychainKeys.rememberedUsers(serverID: known.id))
        }

        try? keychainService.delete(for: KeychainKeys.knownServers)
        try? keychainService.delete(for: KeychainKeys.activeServerID)
        try? keychainService.delete(for: "activeUserName")
        try? keychainService.delete(for: "activeUserImageTag")

        jellyfinClient.baseURL = nil
        jellyfinClient.accessToken = nil

        SharedSessionMirror.clear()

        try clearSeerrSession()
    }

    /// See `restoreSession()` for the rationale behind silent `try?` here.
    func restoreSeerrSession() -> SeerrServer? {
        guard let serverData = try? keychainService.loadData(for: KeychainKeys.seerrServer),
              let server = try? JSONDecoder().decode(SeerrServer.self, from: serverData),
              let cookie = try? keychainService.loadString(for: KeychainKeys.seerrSession(serverID: server.id))
        else {
            return nil
        }

        seerrClient.baseURL = server.url
        seerrClient.sessionCookie = cookie
        return server
    }

    func saveSeerrSession(
        server: SeerrServer,
        forJellyfinUserID jellyfinUserID: String? = nil,
        jellyfinServerID: String? = nil
    ) throws {
        let serverData = try JSONEncoder().encode(server)
        try keychainService.save(serverData, for: KeychainKeys.seerrServer)
        if let cookie = seerrClient.sessionCookie {
            try keychainService.save(cookie, for: KeychainKeys.seerrSession(serverID: server.id))
        }
        seerrClient.baseURL = server.url

        // Additionally persist a per-(Jellyfin-user) copy so profile
        // switching can restore the right Seerr session for each
        // profile. Skipped when either ID is missing, callers pass
        // both when they can (SeerrSettingsView has the full app
        // state), nothing when the login happens outside of any
        // Jellyfin-user context.
        if let jellyfinUserID, let jellyfinServerID, let cookie = seerrClient.sessionCookie {
            let remembered = RememberedSeerrSession(
                jellyfinUserID: jellyfinUserID,
                jellyfinServerID: jellyfinServerID,
                seerrServer: server,
                cookie: cookie
            )
            let data = try JSONEncoder().encode(remembered)
            try keychainService.save(
                data,
                for: KeychainKeys.rememberedSeerr(
                    jellyfinServerID: jellyfinServerID,
                    jellyfinUserID: jellyfinUserID
                )
            )
        }
    }

    /// Restore the Seerr session that belongs to a specific Jellyfin
    /// profile. Returns the SeerrServer on success so the caller can
    /// kick off `seerrAuthService.currentUser()` and surface the
    /// result to AppState. Returns nil when the profile has no
    /// remembered Seerr session, in which case the caller should
    /// clear Seerr state.
    func restoreSeerrSession(
        forJellyfinUserID jellyfinUserID: String,
        jellyfinServerID: String
    ) -> SeerrServer? {
        let key = KeychainKeys.rememberedSeerr(
            jellyfinServerID: jellyfinServerID,
            jellyfinUserID: jellyfinUserID
        )
        guard let data = try? keychainService.loadData(for: key),
              let remembered = try? JSONDecoder().decode(RememberedSeerrSession.self, from: data)
        else {
            return nil
        }
        seerrClient.baseURL = remembered.seerrServer.url
        seerrClient.sessionCookie = remembered.cookie
        return remembered.seerrServer
    }

    /// Per-profile Seerr forget, used when a stored Seerr session
    /// fails to restore (server rotated, cookie expired, user
    /// revoked). Leaves other profiles' sessions alone.
    func forgetRememberedSeerr(forJellyfinUserID jellyfinUserID: String, jellyfinServerID: String) {
        try? keychainService.delete(
            for: KeychainKeys.rememberedSeerr(
                jellyfinServerID: jellyfinServerID,
                jellyfinUserID: jellyfinUserID
            )
        )
    }

    func clearSeerrSession() throws {
        if let serverData = try? keychainService.loadData(for: KeychainKeys.seerrServer),
           let decoded = try? JSONDecoder().decode(SeerrServer.self, from: serverData) {
            try keychainService.delete(for: KeychainKeys.seerrSession(serverID: decoded.id))
        }
        try keychainService.delete(for: KeychainKeys.seerrServer)

        seerrClient.baseURL = nil
        seerrClient.sessionCookie = nil
    }
}
