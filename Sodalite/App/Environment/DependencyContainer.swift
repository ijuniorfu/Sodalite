import Foundation
import AetherEngine

@MainActor
@Observable
final class DependencyContainer {
    /// The one and only container. Both the App's `@State` and the
    /// `@Environment` default value resolve to this, so exactly one
    /// container (and one MusicPlaybackCoordinator subscribed to the
    /// singleton engine) ever exists. Building a second one spawns a
    /// "zombie" coordinator that clears system Now-Playing on every engine
    /// state change, fighting the real one.
    static let shared = DependencyContainer()

    @MainActor static let playerEngine: AetherEngine = try! AetherEngine()
    let keychainService: KeychainServiceProtocol
    let httpClient: HTTPClientProtocol
    let jellyfinClient: JellyfinClient
    let serverDiscoveryService: ServerDiscoveryServiceProtocol
    let jellyfinAuthService: JellyfinAuthServiceProtocol
    let jellyfinLibraryService: JellyfinLibraryServiceProtocol
    let jellyfinLiveTvService: JellyfinLiveTvServiceProtocol
    let jellyfinMusicService: JellyfinMusicServiceProtocol
    let jellyfinItemService: JellyfinItemServiceProtocol
    let jellyfinSearchService: JellyfinSearchServiceProtocol
    let jellyfinImageService: JellyfinImageService
    let jellyfinPlaybackService: JellyfinPlaybackServiceProtocol
    let playbackPreferences: PlaybackPreferences
    let storeKitService: StoreKitServiceProtocol
    let appearancePreferences: AppearancePreferences
    let authPreferences: AuthPreferences
    let tvProfileMappings: TVProfileMappings

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

    let musicPlaybackCoordinator: MusicPlaybackCoordinator

    /// Back-reference to AppState so switchServer / removeServer can
    /// bump the serverDidSwitch signal without threading AppState
    /// through every call site. Weak to avoid a retain cycle
    /// (AppState does not own DependencyContainer).
    weak var appState: AppState?

    init(
        keychainService: KeychainServiceProtocol = KeychainService(),
        httpClient: HTTPClientProtocol = HTTPClient()
    ) {
        // One-shot keychain hygiene (pre-entitlement wipe, see
        // KeychainMigrator). Idempotent; has to run BEFORE
        // keychainService is touched.
        KeychainMigrator.migrateIfNeeded()

        self.keychainService = keychainService
        self.httpClient = httpClient
        self.jellyfinClient = JellyfinClient(httpClient: httpClient)
        self.serverDiscoveryService = ServerDiscoveryService(httpClient: httpClient)
        self.jellyfinAuthService = JellyfinAuthService(client: jellyfinClient)
        self.jellyfinLibraryService = JellyfinLibraryService(client: jellyfinClient)
        self.jellyfinLiveTvService = JellyfinLiveTvService(client: jellyfinClient)
        self.jellyfinMusicService = JellyfinMusicService(
            client: jellyfinClient,
            libraryService: jellyfinLibraryService
        )
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
        self.tvProfileMappings = TVProfileMappings()

        // The Seerr tree gets its OWN HTTPClient so Catalog browsing
        // (5 discover rows + genre sliders + per-tile backdrop and
        // watch-provider fetches) doesn't compete with the Home
        // fan-out for the same 6 in-flight permits against a possibly
        // tarpitted Jellyfin CDN; see the inFlightLimiter rationale
        // in HTTPClient.
        let seerrHTTPClient = HTTPClient()
        self.seerrClient = SeerrClient(httpClient: seerrHTTPClient)
        self.seerrServerDiscoveryService = SeerrServerDiscoveryService(httpClient: seerrHTTPClient)
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

        // musicPlaybackCoordinator is assigned last. The userIDProvider
        // closure captures keychainService directly (strong); this is
        // safe because the coordinator's lifetime is scoped to the
        // container that owns keychainService. Replicates activeUserID
        // without closing over self, which Swift forbids before init
        // is complete.
        let capturedKeychain = keychainService
        self.musicPlaybackCoordinator = MusicPlaybackCoordinator(
            engine: DependencyContainer.playerEngine,
            playbackService: jellyfinPlaybackService,
            imageService: jellyfinImageService,
            userIDProvider: {
                guard let serverID = try? capturedKeychain.loadString(for: KeychainKeys.activeServerID)
                else { return nil }
                return try? capturedKeychain.loadString(for: KeychainKeys.userID(serverID: serverID))
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
            SharedSessionMirror.clear(tvUserID: TVUserContext.currentUserID)
            forgetRememberedSeerr(
                forJellyfinUserID: userID,
                jellyfinServerID: server.id
            )
            return nil
        }
    }

    /// Light probe: does the active server expose any Live TV channels?
    /// Used to gate the Live TV tab. Returns false on any error.
    func serverHasLiveTV(userID: String) async -> Bool {
        do {
            let response = try await jellyfinLiveTvService.getChannels(
                userID: userID, startIndex: 0, limit: 1)
            return !response.items.isEmpty
        } catch {
            return false
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
            SharedSessionMirror.write(
                tvUserID: TVUserContext.currentUserID,
                serverURL: server.url,
                userID: userID,
                accessToken: token
            )
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
        try keychainService.save(user.name, for: KeychainKeys.activeUserName)

        // Persist the avatar image tag so Settings can render the
        // profile picture across cold launches instead of falling
        // back to initials. If the user has no custom avatar, clear
        // any previously-stored tag so a removed image doesn't
        // linger and 404 on every restore.
        if let tag = user.primaryImageTag, !tag.isEmpty {
            try keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }

        if let password, !password.isEmpty {
            try keychainService.save(password, for: KeychainKeys.jellyfinPassword(serverID: server.id))
        }

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        SharedSessionMirror.write(
            tvUserID: TVUserContext.currentUserID,
            serverURL: server.url,
            userID: user.id,
            accessToken: token
        )

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

        if let tvUserID = TVUserContext.currentUserID {
            tvProfileMappings.setMapping(
                TVProfileMapping(serverID: server.id, jellyfinUserID: user.id),
                for: tvUserID
            )
        }
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

    /// In-place update that preserves list order, unlike `addServer`,
    /// which floats the entry to the front. Used by the version refresh
    /// below so a background metadata change doesn't reshuffle the
    /// profile picker. No-op if the id isn't already known.
    private func updateKnownServer(_ server: JellyfinServer) throws {
        var servers = listKnownServers()
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
    }

    /// Re-fetches the active server's `/System/Info/Public` and, if the
    /// reported version differs from the cached one, updates the
    /// knownServers entry in place. Returns the refreshed server when
    /// the version changed, nil when it was already current or the
    /// fetch failed.
    ///
    /// The version is captured once at discovery (pre-login) and
    /// otherwise never refreshed, so a server upgrade left Settings
    /// showing the stale version until a full logout/login. This is the
    /// refresh path. Reuses the unauthenticated discovery probe against
    /// the active server's resolved URL; the id guard rejects a
    /// different server answering at that address.
    func refreshActiveServerVersion() async -> JellyfinServer? {
        guard let server = activeServer else { return nil }
        guard case .success(_, let info) = await serverDiscoveryService.discoverServer(
            input: server.url.absoluteString
        ) else { return nil }
        guard info.id == server.id, info.version != server.version else { return nil }
        let updated = JellyfinServer(
            id: server.id,
            name: server.name,
            url: server.url,
            version: info.version
        )
        try? updateKnownServer(updated)
        return updated
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

    /// The active Jellyfin user's id, resolved from the keychain for the
    /// active server. nil when there is no active session.
    var activeUserID: String? {
        guard let server = activeServer else { return nil }
        return try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
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
            SharedSessionMirror.clear(tvUserID: TVUserContext.currentUserID)
            throw ServerSwitchError.missingToken
        }

        let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        if let userID {
            SharedSessionMirror.write(
                tvUserID: TVUserContext.currentUserID,
                serverURL: server.url,
                userID: userID,
                accessToken: token
            )
        } else {
            SharedSessionMirror.clear(tvUserID: TVUserContext.currentUserID)
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
        var signalAlreadyScheduled = false
        if activeID == serverID {
            if let successor = servers.first {
                do {
                    // A successful switchServer schedules the
                    // serverDidSwitch bump itself; a second bump here
                    // would cancel the first probe mid-flight via the
                    // .task(id:) re-key and double the Home reload.
                    try switchServer(to: successor.id)
                    signalAlreadyScheduled = true
                } catch {
                    // Missing token: the pointer moved but switchServer
                    // threw before scheduling its bump. Fall through to
                    // the trailing bump so AppRouter still reacts and
                    // routes to the successor's profile picker.
                }
            } else {
                try? keychainService.delete(for: KeychainKeys.activeServerID)
                jellyfinClient.baseURL = nil
                jellyfinClient.accessToken = nil
                SharedSessionMirror.clear(tvUserID: TVUserContext.currentUserID)
            }
        }

        tvProfileMappings.removeMappings(forServer: serverID)

        if !signalAlreadyScheduled {
            Task { @MainActor in
                self.appState?.serverDidSwitch &+= 1
            }
        }
    }

    /// Roll the active-server pointer back to a previous value.
    /// Used when a post-switch probe fails with a transport error
    /// (network down, server unreachable). Resets JellyfinClient
    /// and SharedSessionMirror to the rollback target's cached
    /// state so the rest of the app sees a consistent snapshot of
    /// the previous server.
    func rollbackSwitch(to serverID: String) throws {
        // A plain switchServer: it restores pointer + client +
        // mirror to the rollback target and issues one
        // serverDidSwitch bump, which is all observers need. Kept as
        // a named alias so call sites read as rollbacks.
        try switchServer(to: serverID)
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
        tvProfileMappings.removeMapping(forUser: id, on: serverID)
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
        try keychainService.save(remembered.name, for: KeychainKeys.activeUserName)

        if let tag = remembered.imageTag, !tag.isEmpty {
            try keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }

        try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: server.id))

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = remembered.token

        SharedSessionMirror.write(
            tvUserID: TVUserContext.currentUserID,
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

        if let tvUserID = TVUserContext.currentUserID {
            tvProfileMappings.setMapping(
                TVProfileMapping(serverID: server.id, jellyfinUserID: remembered.id),
                for: tvUserID
            )
        }
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
        try? keychainService.delete(for: KeychainKeys.activeUserName)
        try? keychainService.delete(for: KeychainKeys.activeUserImageTag)

        jellyfinClient.baseURL = nil
        jellyfinClient.accessToken = nil

        SharedSessionMirror.clearAll()

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
        seerrClient.baseURL = server.url

        if let jellyfinUserID, let jellyfinServerID, let cookie = seerrClient.sessionCookie {
            // Profile-scoped persistence so profile switching can
            // restore the right Seerr session for each profile. The
            // global (pre-0.3.0) entry is deliberately NOT refreshed
            // here anymore: it used to be rewritten on every login,
            // which kept the legacy fallback perpetually live, and a
            // profile without a scoped entry could inherit whichever
            // profile last logged in. The global keys are read-only
            // legacy now (see syncSeerrSession).
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
        } else {
            // Login outside any Jellyfin-user context: the global
            // entry is the only place to persist it.
            let serverData = try JSONEncoder().encode(server)
            try keychainService.save(serverData, for: KeychainKeys.seerrServer)
            if let cookie = seerrClient.sessionCookie {
                try keychainService.save(cookie, for: KeychainKeys.seerrSession(serverID: server.id))
            }
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

    /// Restore-and-validate flow for the Seerr session that belongs to
    /// a Jellyfin profile. This is the single owner of the
    /// "restore → probe /auth/me → keep or drop" policy; every restore
    /// path (launch, profile switch, server switch, add-profile) maps
    /// the returned outcome onto AppState instead of re-implementing
    /// the sequence.
    ///
    /// The keychain entry is only dropped on an authentication
    /// rejection (401/403), per the RememberedSeerrSession contract.
    /// Transport failures (timeout, unreachable, Seerr container
    /// restarting) keep the entry so the session comes back on the
    /// next launch instead of forcing a re-login.
    func syncSeerrSession(
        forJellyfinUserID jellyfinUserID: String?,
        jellyfinServerID: String?,
        allowLegacyFallback: Bool = false
    ) async -> SeerrSyncOutcome {
        let scopedServer: SeerrServer? = {
            guard let jellyfinUserID, let jellyfinServerID else { return nil }
            return restoreSeerrSession(
                forJellyfinUserID: jellyfinUserID,
                jellyfinServerID: jellyfinServerID
            )
        }()

        // Legacy global fallback (pre-0.3.0 single-session entry) so
        // old installs still come back on first upgrade. Only consulted
        // when the profile has no scoped entry of its own.
        let server = scopedServer ?? (allowLegacyFallback ? restoreSeerrSession() : nil)

        guard let server else {
            // No remembered session anywhere: make sure no stale
            // client/global state lingers from a previous profile.
            try? clearSeerrSession()
            return .notConfigured
        }

        do {
            let user = try await seerrAuthService.currentUser()

            // Legacy bridge: a session restored via the global entry
            // gets persisted as a scoped copy so the next profile
            // switch can bring it back without the fallback. Once the
            // scoped copy exists, retire the global entry: leaving it
            // around lets a DIFFERENT profile without a scoped entry
            // inherit this cookie at a later cold launch.
            if scopedServer == nil, let jellyfinUserID, let jellyfinServerID {
                try? saveSeerrSession(
                    server: server,
                    forJellyfinUserID: jellyfinUserID,
                    jellyfinServerID: jellyfinServerID
                )
                try? keychainService.delete(for: KeychainKeys.seerrSession(serverID: server.id))
                try? keychainService.delete(for: KeychainKeys.seerrServer)
            }
            return .connected(server: server, user: user)
        } catch let error as APIError where error.isUnauthorized {
            // The server rejected the cookie: this entry is dead,
            // drop it (scoped copy only when that was the one probed,
            // keeps other profiles' sessions untouched).
            if scopedServer != nil, let jellyfinUserID, let jellyfinServerID {
                forgetRememberedSeerr(
                    forJellyfinUserID: jellyfinUserID,
                    jellyfinServerID: jellyfinServerID
                )
            }
            try? clearSeerrSession()
            return .invalidated
        } catch {
            // Timeout / unreachable / cancellation: NOT a verdict on
            // the cookie. Keep the keychain entry, leave the client
            // configured, just don't mark the session connected.
            return .transientFailure
        }
    }
}

/// Result of `syncSeerrSession`. Callers map this onto AppState:
/// `.connected` → `setSeerrConnected`, everything else →
/// `disconnectSeerr()` (the keychain handling already happened
/// inside the container).
enum SeerrSyncOutcome {
    case connected(server: SeerrServer, user: SeerrUser)
    /// No remembered session for this profile.
    case notConfigured
    /// Server rejected the stored cookie; entry was forgotten.
    case invalidated
    /// Transport failure; entry kept for a later retry.
    case transientFailure
}
