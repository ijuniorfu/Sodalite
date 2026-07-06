import Foundation
import AetherEngine

@MainActor
@Observable
final class DependencyContainer {
    /// Single instance (App `@State` + `@Environment` default both resolve here). A second container spawns a zombie MusicPlaybackCoordinator that clears system Now-Playing on every engine state change.
    static let shared = DependencyContainer()

    @MainActor static let playerEngine: AetherEngine = try! AetherEngine()
    let keychainService: KeychainServiceProtocol
    let httpClient: HTTPClientProtocol
    let jellyfinClient: JellyfinClient
    let serverDiscoveryService: ServerDiscoveryServiceProtocol
    let serverDiscovery: JellyfinServerDiscoveryProtocol
    let jellyfinAuthService: JellyfinAuthServiceProtocol
    let jellyfinLibraryService: JellyfinLibraryServiceProtocol
    let jellyfinLiveTvService: JellyfinLiveTvServiceProtocol
    let jellyfinMusicService: JellyfinMusicServiceProtocol
    let jellyfinItemService: JellyfinItemServiceProtocol
    let jellyfinImageService: JellyfinImageService
    let jellyfinPlaybackService: JellyfinPlaybackServiceProtocol
    let playbackPreferences: PlaybackPreferences
    let storeKitService: StoreKitServiceProtocol
    let appearancePreferences: AppearancePreferences
    let authPreferences: AuthPreferences
    let parentalControlsPreferences: ParentalControlsPreferences
    let parentalGate: ParentalGate
    let tvProfileMappings: TVProfileMappings

    let seerrClient: SeerrClient
    let seerrServerDiscoveryService: SeerrServerDiscoveryServiceProtocol
    let seerrAuthService: SeerrAuthServiceProtocol
    let seerrDiscoverService: SeerrDiscoverServiceProtocol
    let seerrMediaService: SeerrMediaServiceProtocol
    let seerrRequestService: SeerrRequestServiceProtocol
    let seerrServiceConfigService: SeerrServiceConfigServiceProtocol
    let seerrSearchService: SeerrSearchServiceProtocol

    /// Opt-in + baseline for the pending-requests notification feature (iOS/iPadOS).
    let seerrNotificationPreferences: SeerrNotificationPreferences
    /// Count of requests pending approval (admin only); feeds the Catalog tab badge + background refresh.
    let pendingRequestsMonitor: PendingRequestsMonitor

    /// File-deletion service fronting Jellyfin + Seerr; gated on JellyfinUser.canDeleteContent.
    let mediaDeletionService: any MediaDeletionServiceProtocol

    let musicPlaybackCoordinator: MusicPlaybackCoordinator

    /// Back-reference so switchServer / removeServer can bump serverDidSwitch. Weak: AppState does not own the container.
    weak var appState: AppState?

    init(
        keychainService: KeychainServiceProtocol = KeychainService(),
        httpClient: HTTPClientProtocol = HTTPClient()
    ) {
        // One-shot keychain hygiene (KeychainMigrator); idempotent, must run BEFORE keychainService is touched.
        KeychainMigrator.migrateIfNeeded()

        self.keychainService = keychainService
        self.httpClient = httpClient
        self.jellyfinClient = JellyfinClient(httpClient: httpClient)
        self.serverDiscoveryService = ServerDiscoveryService(httpClient: httpClient)
        self.serverDiscovery = JellyfinServerDiscovery()
        self.jellyfinAuthService = JellyfinAuthService(client: jellyfinClient)
        self.jellyfinLibraryService = JellyfinLibraryService(client: jellyfinClient)
        self.jellyfinLiveTvService = JellyfinLiveTvService(client: jellyfinClient)
        self.jellyfinMusicService = JellyfinMusicService(
            client: jellyfinClient,
            libraryService: jellyfinLibraryService
        )
        self.jellyfinItemService = JellyfinItemService(client: jellyfinClient)
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
        self.parentalControlsPreferences = ParentalControlsPreferences()
        self.parentalGate = ParentalGate()
        self.tvProfileMappings = TVProfileMappings()

        // Seerr gets its OWN HTTPClient so Catalog browsing doesn't compete with the Home fan-out for the same 6 in-flight permits against a tarpitted Jellyfin CDN (see HTTPClient inFlightLimiter).
        let seerrHTTPClient = HTTPClient()
        self.seerrClient = SeerrClient(httpClient: seerrHTTPClient)
        self.seerrServerDiscoveryService = SeerrServerDiscoveryService(httpClient: seerrHTTPClient)
        self.seerrAuthService = SeerrAuthService(client: seerrClient)
        self.seerrDiscoverService = SeerrDiscoverService(client: seerrClient)
        self.seerrMediaService = SeerrMediaService(client: seerrClient)
        self.seerrRequestService = SeerrRequestService(client: seerrClient)
        self.seerrServiceConfigService = SeerrServiceConfigService(client: seerrClient)
        self.seerrSearchService = SeerrSearchService(client: seerrClient)

        self.seerrNotificationPreferences = SeerrNotificationPreferences()
        self.pendingRequestsMonitor = PendingRequestsMonitor()

        self.mediaDeletionService = MediaDeletionService(
            jellyfinItems: self.jellyfinItemService,
            seerrMedia: self.seerrMediaService,
            isSeerrAuthenticated: { [weak seerrClient] in
                // Live read each invocation (no caching); cookie is set on login, cleared on logout/restore failure.
                seerrClient?.sessionCookie != nil
            }
        )

        // userIDProvider captures keychainService strongly (safe: coordinator lifetime is scoped to the container). Replicates activeUserID without closing over self, forbidden pre-init.
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

    /// Connect the pending-requests monitor to the live session. Called once from SodaliteApp.init
    /// right after `appState` is back-wired, so the closures capture the fully-initialized container.
    func wirePendingRequestsMonitor() {
        pendingRequestsMonitor.isEligible = { [weak self] in
            guard let self, let user = self.appState?.activeSeerrUser else { return false }
            return (self.appState?.isSeerrConnected ?? false) && user.canManageRequests
        }
        pendingRequestsMonitor.fetchPendingCount = { [weak self] in
            guard let self else { return 0 }
            let result = try await self.seerrRequestService.allRequests(filter: .pending, take: 0, skip: 0)
            return result.pageInfo.results
        }
    }

    /// Probes /Users/Me against the active server. Returns the user on success; on 401 drops the remembered entry + token slot and returns nil (caller routes to picker); throws on transport errors (caller keeps previous server active).
    @MainActor
    func probeActiveUser() async throws -> JellyfinUser? {
        guard let server = activeServer,
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        else { return nil }

        // Tokenless short-circuit: switchServer can move the pointer then throw on an empty token slot (removeServer fall-through). Probing would issue an unauthenticated request carrying stale client state. No token means picker.
        guard (try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))) != nil
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

    /// Gates the Live TV tab: does the active server expose any Live TV channels? False on any error.
    func serverHasLiveTV(userID: String) async -> Bool {
        do {
            let response = try await jellyfinLiveTvService.getChannels(
                userID: userID, startIndex: 0, limit: 1)
            return !response.items.isEmpty
        } catch {
            return false
        }
    }

    /// Silent `try?`: a missing/unreadable keychain entry means no session to restore (app falls back to login); no recovery path benefits from the underlying error.
    func restoreSession() -> Bool {
        guard let server = activeServer,
              let token = try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id))
        else {
            return false
        }

        jellyfinClient.baseURL = server.url
        jellyfinClient.accessToken = token

        // Re-project SharedSessionMirror every cold launch so TopShelf stays in lockstep even if a prior version never wrote it or the shelf's bucket was wiped.
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

        // Persist avatar tag for cold-launch rendering; clear a stale tag when the user has none so a removed image doesn't linger and 404.
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

        // Upsert into remembered-profiles so the user can later switch profiles without re-auth.
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

    /// All servers ever logged into and not removed, most-recently-upserted first. Empty on fresh install / all removed.
    func listKnownServers() -> [JellyfinServer] {
        guard let data = try? keychainService.loadData(for: KeychainKeys.knownServers)
        else { return [] }
        return (try? JSONDecoder().decode([JellyfinServer].self, from: data)) ?? []
    }

    /// Upsert by id, prepending so a re-added server (e.g. changed URL) updates in place and floats to the top of pickers.
    func addServer(_ server: JellyfinServer) throws {
        var servers = listKnownServers().filter { $0.id != server.id }
        servers.insert(server, at: 0)
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
    }

    /// In-place update preserving list order (unlike addServer) so a background version refresh doesn't reshuffle the picker. No-op if id unknown.
    private func updateKnownServer(_ server: JellyfinServer) throws {
        var servers = listKnownServers()
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        let data = try JSONEncoder().encode(servers)
        try keychainService.save(data, for: KeychainKeys.knownServers)
    }

    /// Refreshes the cached server version (captured once at discovery, else stale in Settings until logout/login) via the unauthenticated discovery probe; updates knownServers in place. Returns the refreshed server only if the version changed; nil otherwise. id guard rejects a different server answering at the URL.
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

    /// Resolves the active-server pointer against knownServers. nil if missing or unresolved (the latter repaired in SessionRestorer.restore).
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

    /// Switches the active server: sets the pointer, loads the cached token, reconfigures JellyfinClient, rewrites SharedSessionMirror, bumps serverDidSwitch. Seerr is left to the caller's restore path. Throws .unknown (not in knownServers) or .missingToken (caller routes to login).
    func switchServer(to serverID: String) throws {
        guard let server = listKnownServers().first(where: { $0.id == serverID }) else {
            throw ServerSwitchError.unknown
        }

        // Stop session-scoped background music at the source, before the session changes. The AppRouter
        // activeSessionIdentity onChange only catches the completed setAuthenticated, which lags the async
        // probe on a server switch (and never fires on the .missingToken picker route below), so the previous
        // server's track would keep playing. Covers removeServer's active-server promotion (it calls this).
        Task { @MainActor in
            if self.musicPlaybackCoordinator.currentItem != nil {
                self.musicPlaybackCoordinator.stop()
            }
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

        // Seerr (per server+user) is left to the caller's post-switch restore path so callers can route to a picker first when userID is nil.
        Task { @MainActor in
            self.appState?.serverDidSwitch &+= 1
        }
    }

    /// Removes a server and all state scoped to it (token, password, remembered users + Seerr sessions). If it was active and others remain, promotes the most-recent survivor (restore path handles expired tokens); if none remain, clears the pointer + SharedSessionMirror so next launch lands in ServerDiscoveryView.
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
                    // switchServer bumps serverDidSwitch itself; a second bump would re-key .task(id:), cancel the first probe, and double the Home reload.
                    try switchServer(to: successor.id)
                    signalAlreadyScheduled = true
                } catch {
                    // Missing token: pointer moved but no bump scheduled. Fall through to the trailing bump so AppRouter routes to the picker.
                }
            } else {
                try? keychainService.delete(for: KeychainKeys.activeServerID)
                jellyfinClient.baseURL = nil
                jellyfinClient.accessToken = nil
                SharedSessionMirror.clear(tvUserID: TVUserContext.currentUserID)
            }
        }

        tvProfileMappings.removeMappings(forServer: serverID)

        // Only signal when the ACTIVE server was removed; an inactive removal's bump would needlessly cancel probes + force a Home reload.
        if activeID == serverID, !signalAlreadyScheduled {
            Task { @MainActor in
                self.appState?.serverDidSwitch &+= 1
            }
        }
    }

    /// Rolls the active-server pointer back after a transport-error probe failure. Named alias for switchServer (restores pointer + client + mirror, one bump) so call sites read as rollbacks.
    func rollbackSwitch(to serverID: String) throws {
        try switchServer(to: serverID)
    }

    // MARK: - Remembered Profiles

    /// All token-cached profiles for a server, most-recently-added first so fresh logins float to the top of pickers.
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

    /// Swaps to a remembered profile: reuses cached token, updates active-session keychain, reconfigures client. Drops the cached Jellyfin password (per-server, not per-user) so Seerr auto-fill doesn't carry the previous user's password.
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

        // Seerr left to the caller's restoreSeerrSession(forJellyfinUserID:jellyfinServerID:) so each profile picks up its own session, or lands on the empty state.
        if let tvUserID = TVUserContext.currentUserID {
            tvProfileMappings.setMapping(
                TVProfileMapping(serverID: server.id, jellyfinUserID: remembered.id),
                for: tvUserID
            )
        }
    }

    /// Refreshes active-user details after a profile switch. /Users/Me supplies the Policy block (canDeleteContent gate, else stuck on the keychain stub with policy: nil); /Users/Public is the imageTag-only fallback backfilling a nil/stale RememberedUser tag. `expectedUserID` discards the result if a racing switch changed the active profile. Persists tag to keychain + remembered entry, returns the fresh user; nil on guard trip / no change.
    func refreshActiveUserDetails(
        expectedUserID userID: String,
        serverID: String
    ) async -> JellyfinUser? {
        let me: JellyfinUser? = try? await jellyfinAuthService.getCurrentUser()
        let directTag: String? = (me?.id == userID) ? me?.primaryImageTag : nil
        // /Users/Public fallback when directTag is nil (some Jellyfin versions only populate the tag on the public listing, not the authenticated detail endpoint).
        let fallbackTag: String? = directTag == nil ? await fetchPublicImageTag(for: userID) : nil
        let tag = directTag ?? fallbackTag

        guard appState?.activeUser?.id == userID,
              let current = appState?.activeUser else { return nil }

        // Apply the fetched policy when /Users/Me succeeded; else keep the existing value (no-op, not a regression).
        let freshPolicy = (me?.id == userID) ? me?.policy : current.policy
        let tagChanged = current.primaryImageTag != tag
        let policyChanged = current.policy != freshPolicy
        guard tagChanged || policyChanged else { return nil }

        let fresh = JellyfinUser(
            id: current.id,
            name: current.name,
            serverID: current.serverID,
            hasPassword: current.hasPassword,
            primaryImageTag: tag,
            policy: freshPolicy
        )
        if let tag, !tag.isEmpty {
            try? keychainService.save(tag, for: KeychainKeys.activeUserImageTag)
        } else {
            try? keychainService.delete(for: KeychainKeys.activeUserImageTag)
        }
        if let existing = listRememberedUsers(serverID: serverID)
            .first(where: { $0.id == userID }) {
            try? rememberUser(
                RememberedUser(
                    id: existing.id,
                    serverID: existing.serverID,
                    name: fresh.name,
                    imageTag: tag,
                    token: existing.token,
                    addedAt: existing.addedAt
                )
            )
        }
        return fresh
    }

    /// Image-tag lookup against /Users/Public for the fallback path
    /// above. Returns nil if the listing is unavailable or has no
    /// match with a non-empty tag.
    private func fetchPublicImageTag(for userID: String) async -> String? {
        if let publicUsers = try? await jellyfinAuthService.getPublicUsers(),
           let match = publicUsers.first(where: { $0.id == userID }),
           let tag = match.primaryImageTag,
           !tag.isEmpty {
            return tag
        }
        return nil
    }

    func loadJellyfinPassword() -> String? {
        guard let server = activeJellyfinServerID else { return nil }
        return try? keychainService.loadString(for: KeychainKeys.jellyfinPassword(serverID: server))
    }

    private var activeJellyfinServerID: String? {
        try? keychainService.loadString(for: KeychainKeys.activeServerID)
    }

    func clearSession() throws {
        // Full logout: scrub every server's per-server entries, then the multi-server pointers + global active-user keys + client state + SharedSessionMirror.
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

    // MARK: - Parental Controls / Guardian-PIN

    private struct GuardianPINThrottle: Codable {
        var failedAttempts: Int = 0
        /// Unix epoch seconds the lockout expires; nil = not locked.
        var lockoutUntil: TimeInterval?
    }

    enum PINVerifyResult: Equatable {
        case success
        /// Wrong PIN; `remainingBeforeLockout` attempts left in this round.
        case wrong(remainingBeforeLockout: Int)
        /// Too many failures; locked until `until`.
        case lockedOut(until: Date)
    }

    /// Attempts before the first lockout, and the base lockout duration.
    private static let pinMaxAttempts = 5
    private static let pinBaseLockout: TimeInterval = 60
    private static let pinMaxLockout: TimeInterval = 3600

    func isGuardianPINSet() -> Bool {
        (try? keychainService.loadData(for: KeychainKeys.guardianPINBlob)) != nil
    }

    func saveGuardianPIN(_ pin: String) throws {
        let blob = GuardianPINCrypto.makeBlob(pin: pin)
        let data = try JSONEncoder().encode(blob)
        try keychainService.save(data, for: KeychainKeys.guardianPINBlob)
        // A freshly set PIN starts with a clean slate.
        try? keychainService.delete(for: KeychainKeys.guardianPINThrottle)
    }

    func clearGuardianPIN() throws {
        try keychainService.delete(for: KeychainKeys.guardianPINBlob)
        try? keychainService.delete(for: KeychainKeys.guardianPINThrottle)
    }

    private func loadThrottle() -> GuardianPINThrottle {
        guard let data = try? keychainService.loadData(for: KeychainKeys.guardianPINThrottle),
              let throttle = try? JSONDecoder().decode(GuardianPINThrottle.self, from: data)
        else { return GuardianPINThrottle() }
        return throttle
    }

    private func saveThrottle(_ throttle: GuardianPINThrottle) {
        if let data = try? JSONEncoder().encode(throttle) {
            try? keychainService.save(data, for: KeychainKeys.guardianPINThrottle)
        }
    }

    /// Current lockout deadline if one is active and still in the future.
    func guardianPINLockout() -> Date? {
        guard let until = loadThrottle().lockoutUntil else { return nil }
        let date = Date(timeIntervalSince1970: until)
        return date > Date() ? date : nil
    }

    func verifyGuardianPIN(_ pin: String) -> PINVerifyResult {
        let throttle = loadThrottle()
        if let until = throttle.lockoutUntil {
            let date = Date(timeIntervalSince1970: until)
            if date > Date() { return .lockedOut(until: date) }
        }
        guard let data = try? keychainService.loadData(for: KeychainKeys.guardianPINBlob),
              let blob = try? JSONDecoder().decode(GuardianPINCrypto.Blob.self, from: data)
        else {
            // No PIN set: treat as failure so callers never proceed on a
            // missing blob. (Gate decisions already require isGuardianPINSet.)
            return .wrong(remainingBeforeLockout: Self.pinMaxAttempts)
        }

        if GuardianPINCrypto.verify(pin: pin, blob: blob) {
            try? keychainService.delete(for: KeychainKeys.guardianPINThrottle)
            return .success
        }

        // Wrong: bump the counter; lock out after pinMaxAttempts in a row.
        var updated = throttle
        updated.failedAttempts += 1
        if updated.failedAttempts >= Self.pinMaxAttempts {
            // Escalating: first lockout (attempts == max) is the base 60s;
            // each additional wrong guess thereafter doubles it (120s, 240s, ...),
            // capped at pinMaxLockout. rounds = failedAttempts - pinMaxAttempts.
            let rounds = updated.failedAttempts - Self.pinMaxAttempts
            let duration = min(Self.pinMaxLockout, Self.pinBaseLockout * pow(2, Double(rounds)))
            updated.lockoutUntil = Date().timeIntervalSince1970 + duration
            saveThrottle(updated)
            return .lockedOut(until: Date(timeIntervalSince1970: updated.lockoutUntil!))
        }
        saveThrottle(updated)
        return .wrong(remainingBeforeLockout: Self.pinMaxAttempts - updated.failedAttempts)
    }

    // MARK: Gate decisions

    /// Parental controls are engaged when a PIN is set AND at least one
    /// remembered profile (on any known server) is marked protected.
    func parentalControlsActive() -> Bool {
        guard isGuardianPINSet() else { return false }
        return parentalControlsPreferences.hasAnyProtectedProfile
    }

    /// The (serverID, userID) of the active session, read from the
    /// keychain pointers so this works before AppState is populated.
    private func activeSessionIdentity() -> (serverID: String, userID: String)? {
        guard let serverID = try? keychainService.loadString(for: KeychainKeys.activeServerID),
              let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))
        else { return nil }
        return (serverID, userID)
    }

    /// Is the currently active session a protected profile?
    func activeProfileIsProtected() -> Bool {
        guard let id = activeSessionIdentity() else { return false }
        return parentalControlsPreferences.isProtected(serverID: id.serverID, userID: id.userID)
    }

    /// Whether activating the given target profile needs the Guardian-PIN.
    /// Required when parental controls are active, the target is NOT
    /// protected, and either we are at cold-start (no trusted session
    /// yet) or the current session is itself a protected profile.
    func parentalGateRequired(forActivatingUserID userID: String,
                              serverID: String,
                              isColdStart: Bool) -> Bool {
        guard parentalControlsActive() else { return false }
        if parentalControlsPreferences.isProtected(serverID: serverID, userID: userID) {
            return false // entering a protected profile is always free
        }
        return isColdStart || activeProfileIsProtected()
    }

    /// Whether a session-scoped escape action (logout, server management,
    /// opening parental settings, switching server from the picker)
    /// needs the PIN. Required only while a protected profile is active.
    func parentalGateRequiredForSessionAction() -> Bool {
        parentalControlsActive() && activeProfileIsProtected()
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
            // Profile-scoped persistence. The global (pre-0.3.0) entry is NOT refreshed here: rewriting it kept the legacy fallback live and let a scopeless profile inherit whoever last logged in. Global keys are read-only legacy now (see syncSeerrSession).
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
        } else if jellyfinUserID == nil || jellyfinServerID == nil {
            // Login outside any Jellyfin-user context: the global entry is the only place to persist. Not reached when a profile context exists (that would refresh the deprecated legacy entry).
            let serverData = try JSONEncoder().encode(server)
            try keychainService.save(serverData, for: KeychainKeys.seerrServer)
            if let cookie = seerrClient.sessionCookie {
                try keychainService.save(cookie, for: KeychainKeys.seerrSession(serverID: server.id))
            }
        }
    }

    /// Restores a specific profile's Seerr session. Returns the SeerrServer so the caller can probe currentUser(); nil when the profile has none (caller clears Seerr state).
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

    /// Drops the in-memory Seerr identity without touching keychain. Used on tvOS-user change: the previous user's persisted session must survive, but the live client must stop acting as them immediately.
    func detachSeerrClient() {
        seerrClient.baseURL = nil
        seerrClient.sessionCookie = nil
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

    /// Single owner of the Seerr "restore → probe /auth/me → keep or drop" policy; every restore path maps the outcome onto AppState. Entry dropped only on 401/403 (RememberedSeerrSession contract); transport failures keep it so the session returns next launch.
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

        // Legacy global fallback (pre-0.3.0) so old installs return on first upgrade. Only when the profile has no scoped entry.
        let server = scopedServer ?? (allowLegacyFallback ? restoreSeerrSession() : nil)

        guard let server else {
            // No remembered session anywhere: clear any stale client/global state from a previous profile.
            try? clearSeerrSession()
            return .notConfigured
        }

        do {
            let user = try await seerrAuthService.currentUser()

            // Legacy bridge: persist a globally-restored session as a scoped copy, then retire the global entry (else a DIFFERENT scopeless profile inherits this cookie at a later cold launch).
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
            // Cookie rejected: drop the entry (scoped copy only when that was probed, leaving other profiles untouched).
            if scopedServer != nil, let jellyfinUserID, let jellyfinServerID {
                forgetRememberedSeerr(
                    forJellyfinUserID: jellyfinUserID,
                    jellyfinServerID: jellyfinServerID
                )
            }
            try? clearSeerrSession()
            return .invalidated
        } catch {
            // Timeout / unreachable / cancellation: NOT a verdict on the cookie. Keep the entry + client configured, just don't mark connected.
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
