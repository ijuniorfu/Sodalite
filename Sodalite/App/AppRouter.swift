import SwiftUI
import UIKit
import AetherEngine

struct AppRouter: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase

    /// Tracks whether the initial session restore + splash has already
    /// run for this process. SwiftUI re-fires `.task` when the AppRouter
    /// view temporarily disappears (e.g. while the UIKit-presented
    /// player modal is on screen), without this guard, returning from
    /// the player would show the launch splash again.
    @State private var hasRestored = false
    /// tvOS user identifier as of the last performRestore. Nil before
    /// the first restore completes. Used by the scenePhase observer to
    /// detect "the system user changed since we last fully resolved"
    /// and trigger a full state reset + re-restore, so the previous
    /// user's in-memory session can't bleed through to the new one
    /// when the app process survives a long-press-Home user switch.
    @State private var lastResolvedTVUserID: String?
    @State private var lastResolvedTVUserIDSet = false

    /// Non-nil while the launch-time profile picker is armed: the
    /// restore found a valid session + at least one remembered
    /// profile, and the user either set launchBehavior=.showPicker
    /// or has no default profile pinned. Picking a profile flips
    /// isAuthenticated=true which hides the picker automatically.
    @State private var launchPickerServer: JellyfinServer?

    /// Holds the JellyfinItem fetched for an incoming deep link
    /// (TopShelf cell tap, custom URL invocation). The fullScreenCover
    /// drives off this, non-nil = sheet shown.
    @State private var deepLinkItem: JellyfinItem?

    /// Set true once after the splash hides on a launch where
    /// `ChangelogPreferences.shouldShowOnLaunch()` returned true,
    /// drives the WhatsNew fullScreenCover. Cleared by the modal's
    /// dismiss callback, which also stamps the version as seen so
    /// it stays out of the way until the next upgrade.
    @State private var showWhatsNew = false

    var body: some View {
        ZStack {
            if appState.isAuthenticated {
                TabRootView()
            } else if let server = launchPickerServer {
                LaunchProfilePickerView(server: server)
            } else {
                ServerDiscoveryView()
            }

            // Splash overlays everything until both the session restore
            // has finished AND the minimum display time has elapsed,
            // then it fades out to reveal whichever root view is now
            // appropriate. Cross-fade looks nicer than the old spinner-
            // then-content swap and prevents a jarring snap when restore
            // completes in <100 ms.
            if appState.isLoading {
                SplashView()
                    .transition(.opacity)
            }

            // Covers the previous detail view between the
            // deep-link-driven player dismiss and the new fullScreenCover
            // sliding in. Without this, the user sees the stale detail
            // for ~1-2 s (TopShelf URL → player teardown → item fetch
            // round-trip → cover present).
            if appState.isResolvingDeepLink {
                Color.black
                    .ignoresSafeArea()
                    .overlay {
                        ProgressView()
                            .tint(.white)
                    }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.4), value: appState.isLoading)
        .animation(.easeInOut(duration: 0.2), value: appState.isResolvingDeepLink)
        .task {
            guard !hasRestored else { return }
            hasRestored = true
            await restoreSession()
        }
        .task(id: appState.pendingDeepLinkItemID) {
            await resolvePendingDeepLink()
        }
        .task(id: appState.requestContinueWatching) {
            await resolveContinueWatchingRequest()
        }
        .task(id: scenePhase) {
            // Only react to becoming active. Inactive and background
            // transitions don't need a tvOS-user re-resolve.
            guard scenePhase == .active else { return }
            // Skip until performRestore has set the baseline.
            guard lastResolvedTVUserIDSet else { return }

            let current = TVUserContext.currentUserID
            if current != lastResolvedTVUserID {
                // tvOS system user changed since the last full restore.
                // Reset in-memory app state and re-run performRestore so
                // the previous user's session can't bleed through.
                appState.isAuthenticated = false
                appState.activeServer = nil
                appState.activeUser = nil
                launchPickerServer = nil
                await performRestore()
            } else {
                // Same tvOS user. Cheap re-resolve in case the mapping
                // was edited from Settings on another scene.
                guard appState.isAuthenticated || launchPickerServer != nil else { return }
                await resolveTVUserContext()
            }
        }
        .task(id: appState.serverDidSwitch) {
            guard appState.serverDidSwitch > 0 else { return }
            do {
                let user = try await dependencies.probeActiveUser()
                if let user, let server = dependencies.activeServer {
                    appState.setAuthenticated(server: server, user: user)
                    // Restore the per-(server, user) Seerr session so the
                    // Catalog tab reflects the newly active identity, not
                    // the previous server's session.
                    let seerrServer = dependencies.restoreSeerrSession(
                        forJellyfinUserID: user.id,
                        jellyfinServerID: server.id
                    )
                    if let seerrServer {
                        if let seerrUser = try? await dependencies.seerrAuthService.currentUser() {
                            appState.setSeerrConnected(server: seerrServer, user: seerrUser)
                        } else {
                            dependencies.forgetRememberedSeerr(
                                forJellyfinUserID: user.id,
                                jellyfinServerID: server.id
                            )
                            try? dependencies.clearSeerrSession()
                        }
                    } else {
                        try? dependencies.clearSeerrSession()
                    }
                } else {
                    // Token expired or no remembered user: route to
                    // the profile picker for the new active server.
                    if let server = dependencies.activeServer {
                        launchPickerServer = server
                    }
                    appState.isAuthenticated = false
                }
            } catch {
                // Avoid rollback loops: if appState already holds the
                // currently-active server (because we just rolled back
                // and the probe is still failing), let the failure
                // stand. The next user-driven action will surface it.
                if let previous = appState.activeServer,
                   previous.id != dependencies.activeServer?.id {
                    try? dependencies.rollbackSwitch(to: previous.id)
                }
            }
        }
        .fullScreenCover(item: $deepLinkItem) { item in
            NavigationStack {
                DetailRouterView(item: item)
            }
        }
        .fullScreenCover(isPresented: $showWhatsNew) {
            if let entry = Changelog.latest {
                WhatsNewView(entry: entry) {
                    ChangelogPreferences.markCurrentSeen()
                    showWhatsNew = false
                }
            }
        }
        .onChange(of: appState.isLoading) { _, isLoading in
            // Splash just finished. Fire the What's-New modal if the
            // version stamp says we crossed a release boundary.
            // Pass isAuthenticated so the preference layer can tell
            // a fresh install (don't pester) apart from an upgrade
            // from a pre-Changelog version (0.3.2 and earlier never
            // wrote lastSeenVersion → without this, those users
            // would silently miss the modal forever).
            guard !isLoading else { return }
            if ChangelogPreferences.shouldShowOnLaunch(isExistingUser: appState.isAuthenticated) {
                showWhatsNew = true
            } else {
                ChangelogPreferences.bootstrapIfNeeded()
            }
        }
    }

    /// Promote the (server, profile) tuple pinned to the current
    /// tvOS user, if any. Runs at the top of performRestore and on
    /// every scene-foreground. The tvOS mapping wins over the user's
    /// defaultServerID; the system identity is the more specific
    /// signal. On Apple TVs without multi-user this is a no-op.
    private func resolveTVUserContext() async {
        guard let tvUserID = TVUserContext.currentUserID else { return }
        guard let mapping = dependencies.tvProfileMappings.mapping(for: tvUserID) else { return }

        let currentServerID = try? dependencies.keychainService.loadString(
            for: KeychainKeys.activeServerID
        )
        let currentUserID = try? dependencies.keychainService.loadString(
            for: KeychainKeys.userID(serverID: mapping.serverID)
        )
        let keychainAlreadyMatches = currentServerID == mapping.serverID
            && currentUserID == mapping.jellyfinUserID

        if !keychainAlreadyMatches {
            try? dependencies.switchServer(to: mapping.serverID)
            if let server = dependencies.activeServer,
               let user = dependencies.listRememberedUsers(serverID: mapping.serverID)
                   .first(where: { $0.id == mapping.jellyfinUserID }) {
                try? dependencies.switchToUser(user, server: server)
            }
            // switchServer bumps serverDidSwitch which triggers the
            // probe + setAuthenticated path; nothing else to do here.
            return
        }

        // Keychain already matches the mapping. This happens when the
        // app is resumed for a tvOS user whose state was never wiped
        // (e.g. brief switch away and back). switchServer wouldn't
        // fire, so the serverDidSwitch handler doesn't run, and the
        // AppRouter body can be left showing whatever view the prior
        // tvOS user's session put up (commonly ServerDiscoveryView).
        // Force-flip AppState into authenticated so the body re-renders
        // TabRoot.
        guard !appState.isAuthenticated else { return }
        guard let server = dependencies.activeServer,
              let remembered = dependencies.listRememberedUsers(serverID: mapping.serverID)
                  .first(where: { $0.id == mapping.jellyfinUserID })
        else { return }
        let jf = JellyfinUser(
            id: remembered.id,
            name: remembered.name,
            serverID: server.id,
            hasPassword: nil,
            primaryImageTag: remembered.imageTag,
            policy: nil
        )
        appState.setAuthenticated(server: server, user: jf)
        launchPickerServer = nil
    }

    /// Fetches the active user's first Resume-queue item and feeds
    /// it through the normal deep-link channel. Triggered by
    /// `ContinueWatchingIntent` (Siri / Shortcuts), the intent
    /// itself stays trivial so tvOS-Siri's "no async work" policy
    /// for voice invocation is respected.
    private func resolveContinueWatchingRequest() async {
        guard appState.requestContinueWatching else { return }

        // Same cold-launch wait as the deep-link path: Siri may
        // hand us control before restoreSession finishes.
        while !appState.isAuthenticated, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard let user = appState.activeUser else {
            appState.requestContinueWatching = false
            return
        }

        let response = try? await dependencies.jellyfinLibraryService.getResumeItems(
            userID: user.id,
            mediaType: "Video",
            limit: 1
        )
        appState.requestContinueWatching = false
        if let item = response?.items.first {
            appState.pendingDeepLinkItemID = item.id
        }
    }

    /// Wait until the user is authenticated, fetch the item from
    /// Jellyfin, then trigger the fullScreenCover. Cleared on the way
    /// out so a second tap on the same TopShelf cell re-fires.
    private func resolvePendingDeepLink() async {
        guard let id = appState.pendingDeepLinkItemID else {
            appState.isResolvingDeepLink = false
            return
        }
        // Cold-launch race: the URL arrives before restoreSession
        // finishes. Wait it out, capped at 8 seconds. Pre-multi-server
        // restoreSession either authenticated quickly or short-circuited;
        // in the multi-server world a missing-token state can leave
        // isAuthenticated false while the LaunchProfilePicker is shown,
        // and an unbounded wait here would lock the user out behind
        // our own loading overlay.
        let waitDeadline = Date().addingTimeInterval(8)
        while !appState.isAuthenticated, !Task.isCancelled, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard appState.isAuthenticated, let user = appState.activeUser else {
            // Couldn't restore in time. Drop the pending link and the
            // overlay so the user can interact with whatever AppRouter
            // actually wants to show (picker / discovery).
            appState.pendingDeepLinkItemID = nil
            appState.isResolvingDeepLink = false
            return
        }
        // Ask any active player to dismiss before the new detail
        // sheet is presented. The TopShelf path commonly fires while
        // the app is backgrounded with a paused player on screen;
        // without this signal, the UIKit player modal stays on top
        // of the new SwiftUI fullScreenCover and the user sees the
        // stale session above the freshly routed item.
        //
        // Two-step dismissal: (1) increment the dismissal counter so
        // detail views observing it flip their local showPlayer state
        // (keeps the binding path consistent for when the user returns
        // to the prior detail view); (2) walk the window's modal chain
        // and dismiss any PlayerHostController directly, since the
        // binding-driven dismiss alone proved unreliable across the
        // scene-foreground transition.
        appState.requestPlayerDismissal &+= 1
        dismissActivePlayerModal()
        // Give UIKit a frame to finish the dismiss before we trigger
        // the new fullScreenCover. Without this, the new presentation
        // can race the dismissal and SwiftUI logs the "presenting from
        // a VC that is being dismissed" warning, or the new modal
        // never lands.
        try? await Task.sleep(for: .milliseconds(250))

        let item = try? await dependencies.jellyfinItemService.getItemDetail(
            userID: user.id,
            itemID: id
        )
        appState.pendingDeepLinkItemID = nil
        deepLinkItem = item
        // Hold the overlay a beat past the fullScreenCover binding
        // flip so the cover's slide-in fully obscures the underlying
        // view before we fade our black overlay out.
        try? await Task.sleep(for: .milliseconds(300))
        appState.isResolvingDeepLink = false
    }

    /// Walk the active scene's window-level modal chain and dismiss
    /// the `PlayerHostController` if one is presented. Bypasses the
    /// SwiftUI binding chain because the binding-only path proved
    /// unreliable across the scene-foreground transition: a TopShelf
    /// tap that resumes the app from a paused player would not always
    /// dispatch the local-state mutation through to UIKit fast enough
    /// to let the new fullScreenCover present on top.
    ///
    /// Calling `dismiss(animated:)` on the VC that directly presented
    /// the player removes only that modal level; any other modals in
    /// the chain are left alone. Logged via EngineLog so the
    /// diagnostic overlay can confirm the path ran on TestFlight.
    private func dismissActivePlayerModal() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .background }),
              let window = scene.windows.first(where: { $0.isKeyWindow })
                ?? scene.windows.first
        else {
            EngineLog.emit("[AppRouter] deep-link dismiss: no key window")
            return
        }

        var presenter: UIViewController? = window.rootViewController
        while let current = presenter {
            guard let presented = current.presentedViewController else { break }
            if presented is PlayerHostController {
                EngineLog.emit("[AppRouter] deep-link dismiss: tearing down active player modal")
                current.dismiss(animated: false)
                return
            }
            presenter = presented
        }
        EngineLog.emit("[AppRouter] deep-link dismiss: no player in modal chain")
    }

    /// Records the current tvOS user identifier so the scenePhase
    /// observer can detect a subsequent user change. Called from
    /// every entry point that does a full performRestore.
    private func markTVUserResolved() {
        lastResolvedTVUserID = TVUserContext.currentUserID
        lastResolvedTVUserIDSet = true
    }

    private func restoreSession() async {
        markTVUserResolved()
        appState.isLoading = true
        let splashStart = Date()
        await performRestore()

        // Hold the splash for at least the minimum so the brand moment
        // isn't reduced to a flash on a fast restore path.
        let elapsed = Date().timeIntervalSince(splashStart)
        let remaining = SplashView.minimumDisplayDuration - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
        appState.isLoading = false
    }

    private func performRestore() async {
        // Fire-and-forget: StoreKit lookups are independent of the
        // Jellyfin restore and shouldn't block the splash. The observable
        // isSupporter flag starts from the cached value and flips live
        // once the async refresh completes.
        Task { @MainActor in
            await dependencies.storeKitService.refreshSupporterStatus()
            await dependencies.storeKitService.loadProducts()
        }

        // If the current tvOS user has a (server, Jellyfin profile)
        // mapping recorded, promote it now. The tvOS identity is the
        // more specific signal and wins over any user-pinned default.
        await resolveTVUserContext()

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

            if let target {
                // Point the client at the known host so the picker's
                // avatar fetches + any subsequent LoginView flow hit
                // the right server. We can't recover the access token
                // here, but the host URL is enough to bootstrap the
                // picker.
                dependencies.jellyfinClient.baseURL = target.url
                launchPickerServer = target
            }
            return
        }

        // restoreSession succeeded, so activeServer must resolve and
        // the access token is in place. The guard below is defensive.
        guard let server = dependencies.activeServer else { return }

        guard let userID = try? dependencies.keychainService.loadString(for: KeychainKeys.userID(serverID: server.id)),
              let userName = try? dependencies.keychainService.loadString(for: "activeUserName")
        else {
            // We have a server + token but lost the active-user
            // globals. Don't clearSession (that would nuke every
            // server's per-server state across the install). Land in
            // the picker for this server, the user can re-pick a
            // remembered profile or add a new one.
            launchPickerServer = server
            return
        }

        // primaryImageTag is optional in the keychain, users without
        // a custom avatar never had one persisted. Missing = initials.
        // Fallback path covers JellySeeTV migrations whose last login
        // pre-dated the dedicated activeUserImageTag entry: the
        // RememberedUser blob still carries the tag, so we can lift
        // it from there and re-stamp the canonical key so subsequent
        // restores find it directly.
        let imageTag: String? = {
            if let direct = try? dependencies.keychainService.loadString(for: "activeUserImageTag") {
                return direct
            }
            guard let fromRemembered = dependencies.listRememberedUsers(serverID: server.id)
                .first(where: { $0.id == userID })?
                .imageTag, !fromRemembered.isEmpty
            else { return nil }
            try? dependencies.keychainService.save(fromRemembered, for: "activeUserImageTag")
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
            appState.setAuthenticated(server: server, user: user)
            Task { await refreshActiveUserPolicy(expectedUserID: user.id) }
        } else if remembered.count > 1 {
            launchPickerServer = server
            // Fall through, Seerr restore is independent of which
            // Jellyfin profile ends up active and we want that state
            // ready by the time the user taps a profile.
        } else {
            // Single-profile install (or nothing remembered yet).
            // Enter the app directly, no point showing a picker
            // with one card on it.
            appState.setAuthenticated(server: server, user: restored)
            Task { await refreshActiveUserPolicy(expectedUserID: restored.id) }
        }

        // Seerr restore, prefer the profile-scoped session when the
        // active user has one saved, fall back to the global
        // last-used entry so legacy (pre-0.3.0) Seerr logins still
        // come back on first upgrade.
        let activeUserID = appState.activeUser?.id
        let activeServerID = appState.activeServer?.id
        let scopedSeerrServer: SeerrServer? = {
            guard let uid = activeUserID, let sid = activeServerID else { return nil }
            return dependencies.restoreSeerrSession(forJellyfinUserID: uid, jellyfinServerID: sid)
        }()
        let seerrServer = scopedSeerrServer ?? dependencies.restoreSeerrSession()
        if let seerrServer {
            if let seerrUser = try? await dependencies.seerrAuthService.currentUser() {
                appState.setSeerrConnected(server: seerrServer, user: seerrUser)

                // Legacy bridge: if we restored via the global
                // pre-0.3.0 keychain entry (scopedSeerrServer was
                // nil), persist a per-user copy for the active
                // profile so the next profile switch can bring this
                // session back. Without this, pre-0.3.0 Seerr users
                // would have to re-authenticate after every switch.
                if scopedSeerrServer == nil, let uid = activeUserID, let sid = activeServerID {
                    try? dependencies.saveSeerrSession(
                        server: seerrServer,
                        forJellyfinUserID: uid,
                        jellyfinServerID: sid
                    )
                }
            } else {
                // Only forget the profile-scoped entry when it was the
                // one that failed, keeps other profiles' sessions
                // untouched.
                if scopedSeerrServer != nil, let uid = activeUserID, let sid = activeServerID {
                    dependencies.forgetRememberedSeerr(forJellyfinUserID: uid, jellyfinServerID: sid)
                }
                try? dependencies.clearSeerrSession()
            }
        }
    }

    /// Calls `/Users/Me` to refresh the active user's Policy block.
    /// `expectedUserID` guards against a profile switch that races
    /// the fetch: if the active profile changed between dispatch and
    /// response, we discard the result instead of applying another
    /// user's policy to the now-current user.
    ///
    /// Existed since the File Management feature added a permission
    /// gate driven by `JellyfinUser.canDeleteContent`. The keychain-
    /// bootstrapped restore + profile-switch paths construct the
    /// active user with `policy: nil`; without this refresh, the
    /// permission-gated UI stays hidden until a full logout/login.
    private func refreshActiveUserPolicy(expectedUserID: String) async {
        guard let me = try? await dependencies.jellyfinAuthService.getCurrentUser(),
              me.id == expectedUserID,
              appState.activeUser?.id == expectedUserID
        else { return }
        appState.updateActiveUserPolicy(me.policy)
    }
}
