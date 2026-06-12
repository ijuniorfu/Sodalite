import SwiftUI
import os.log

private let tvUserLogger = Logger(subsystem: "de.superuser404.Sodalite", category: "tvUser")

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
    /// Same re-fire problem as `hasRestored`, for the server-switch
    /// handler: once serverDidSwitch > 0, every player dismissal would
    /// otherwise re-run the full probe + Seerr restore. Records the
    /// last signal value this view actually handled.
    @State private var lastHandledServerSwitch = 0
    /// tvOS user identifier as of the last performRestore. Nil before
    /// the first restore completes. Dormant under the current tvOS
    /// SDK (TVUserManager.currentUserIdentifier is deprecated and
    /// always returns nil), kept in place so the multi-user code path
    /// reactivates automatically if Apple restores the API in a future
    /// tvOS release.
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

    /// Drives the NowPlaying fullScreenCover. Set to true when the
    /// coordinator's `nowPlayingPresentationRequest` bumps (track tap or the
    /// Now-Playing card); cleared on dismiss.
    @State private var showNowPlaying = false

    var body: some View {
        ZStack {
            if appState.isAuthenticated {
                TabRootView()
            } else if let server = launchPickerServer {
                LaunchProfilePickerView(server: server)
            } else {
                ServerDiscoveryView()
            }

            // Now-Playing access is surfaced inside the Music tab (a card at
            // the top) and via a track tap, not a global floating bar (which
            // covered the action buttons in detail views). Both bump the
            // coordinator's presentation request, observed below.

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
            tvUserLogger.notice("scenePhase task fired: phase=\(String(describing: scenePhase), privacy: .public) tvUserID=\(TVUserContext.currentUserID ?? "nil", privacy: .public) last=\(lastResolvedTVUserID ?? "nil", privacy: .public) lastSet=\(lastResolvedTVUserIDSet, privacy: .public) isAuth=\(appState.isAuthenticated, privacy: .public) pickerServer=\(launchPickerServer?.id ?? "nil", privacy: .public)")
            // Only react to becoming active. Inactive and background
            // transitions don't need a tvOS-user re-resolve.
            guard scenePhase == .active else {
                tvUserLogger.notice("scenePhase: skip (not active)")
                return
            }
            // Skip until performRestore has set the baseline.
            guard lastResolvedTVUserIDSet else {
                tvUserLogger.notice("scenePhase: skip (baseline not set yet)")
                return
            }

            let current = TVUserContext.currentUserID
            if current != lastResolvedTVUserID {
                tvUserLogger.notice("scenePhase: tvUser CHANGED last=\(lastResolvedTVUserID ?? "nil", privacy: .public) -> current=\(current ?? "nil", privacy: .public). Wiping state + performRestore.")
                appState.isAuthenticated = false
                appState.activeServer = nil
                appState.activeUser = nil
                // Also drop the previous tvOS user's Seerr identity:
                // performRestore only touches Seerr state when the new
                // user restores a session of their own, so without this
                // wipe the old cookie stays live in seerrClient and the
                // new user would browse/request as the previous one.
                appState.disconnectSeerr()
                try? dependencies.clearSeerrSession()
                launchPickerServer = nil
                markTVUserResolved()
                await performRestore()
            } else {
                tvUserLogger.notice("scenePhase: same tvUser. Cheap resolveTVUserContext.")
                // Same tvOS user. Cheap re-resolve in case the mapping
                // was edited from Settings on another scene.
                guard appState.isAuthenticated || launchPickerServer != nil else {
                    tvUserLogger.notice("scenePhase: skip cheap resolve (no auth, no picker)")
                    return
                }
                await resolveTVUserContext()
            }
        }
        .task(id: appState.serverDidSwitch) {
            guard appState.serverDidSwitch > 0 else { return }
            guard appState.serverDidSwitch != lastHandledServerSwitch else { return }
            lastHandledServerSwitch = appState.serverDidSwitch
            do {
                let user = try await dependencies.probeActiveUser()
                if let user, let server = dependencies.activeServer {
                    appState.setAuthenticated(server: server, user: user)
                    // Restore the per-(server, user) Seerr session so the
                    // Catalog tab reflects the newly active identity, not
                    // the previous server's session.
                    let outcome = await dependencies.syncSeerrSession(
                        forJellyfinUserID: user.id,
                        jellyfinServerID: server.id
                    )
                    if case .connected(let seerrServer, let seerrUser) = outcome {
                        appState.setSeerrConnected(server: seerrServer, user: seerrUser)
                    } else {
                        appState.disconnectSeerr()
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
                // A superseded switch (user picked another server while
                // this probe was in flight) cancels this task; URLSession
                // then throws and we'd misread our own cancellation as a
                // transport failure and roll back the user's NEWER pick.
                // Cancellation is never a verdict on the target server.
                guard !Task.isCancelled else { return }
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
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
        .onChange(of: dependencies.musicPlaybackCoordinator.nowPlayingPresentationRequest) { _, _ in
            // A track tap or the Now-Playing card asked to surface the
            // fullscreen player. The cover state lives here, so drive it.
            showNowPlaying = true
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
        let allMappings = dependencies.tvProfileMappings.allMappings
        tvUserLogger.notice("resolveTVUserContext enter: tvUserID=\(TVUserContext.currentUserID ?? "nil", privacy: .public) totalMappings=\(allMappings.count, privacy: .public) mappingKeys=\(allMappings.keys.joined(separator: ","), privacy: .public)")
        guard let tvUserID = TVUserContext.currentUserID else {
            tvUserLogger.notice("resolveTVUserContext: skip (no tvUserID)")
            return
        }
        guard let mapping = dependencies.tvProfileMappings.mapping(for: tvUserID) else {
            tvUserLogger.notice("resolveTVUserContext: skip (no mapping for \(tvUserID, privacy: .public))")
            return
        }
        tvUserLogger.notice("resolveTVUserContext: mapping found server=\(mapping.serverID, privacy: .public) user=\(mapping.jellyfinUserID, privacy: .public)")

        let currentServerID = try? dependencies.keychainService.loadString(
            for: KeychainKeys.activeServerID
        )
        let currentUserID = try? dependencies.keychainService.loadString(
            for: KeychainKeys.userID(serverID: mapping.serverID)
        )
        let keychainAlreadyMatches = currentServerID == mapping.serverID
            && currentUserID == mapping.jellyfinUserID

        tvUserLogger.notice("resolveTVUserContext: keychain state currentServer=\(currentServerID ?? "nil", privacy: .public) currentUser=\(currentUserID ?? "nil", privacy: .public) matches=\(keychainAlreadyMatches, privacy: .public)")

        if !keychainAlreadyMatches {
            tvUserLogger.notice("resolveTVUserContext: SWITCH path. Calling switchServer + switchToUser")
            try? dependencies.switchServer(to: mapping.serverID)
            if let server = dependencies.activeServer,
               let user = dependencies.listRememberedUsers(serverID: mapping.serverID)
                   .first(where: { $0.id == mapping.jellyfinUserID }) {
                try? dependencies.switchToUser(user, server: server)
                tvUserLogger.notice("resolveTVUserContext: switchToUser done. serverDidSwitch handler will setAuthenticated.")
            } else {
                tvUserLogger.notice("resolveTVUserContext: SWITCH path - server or remembered user missing after switchServer")
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
        guard !appState.isAuthenticated else {
            tvUserLogger.notice("resolveTVUserContext: RESUME path. Already authenticated, no-op.")
            return
        }
        guard let server = dependencies.activeServer,
              let remembered = dependencies.listRememberedUsers(serverID: mapping.serverID)
                  .first(where: { $0.id == mapping.jellyfinUserID })
        else {
            tvUserLogger.notice("resolveTVUserContext: RESUME path - server or remembered user missing. activeServer=\(dependencies.activeServer?.id ?? "nil", privacy: .public) rememberedCount=\(dependencies.listRememberedUsers(serverID: mapping.serverID).count, privacy: .public)")
            return
        }
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
        tvUserLogger.notice("resolveTVUserContext: RESUME path - setAuthenticated done. user=\(remembered.id, privacy: .public) server=\(server.id, privacy: .public)")
    }

    /// Fetches the active user's first Resume-queue item and feeds
    /// it through the normal deep-link channel. Triggered by
    /// `ContinueWatchingIntent` (Siri / Shortcuts), the intent
    /// itself stays trivial so tvOS-Siri's "no async work" policy
    /// for voice invocation is respected.
    private func resolveContinueWatchingRequest() async {
        guard appState.requestContinueWatching else { return }

        // Same cold-launch wait as the deep-link path: Siri may hand
        // us control before restoreSession finishes. Same 8 s cap as
        // the deep-link path: on a fresh install / picker screen an
        // unbounded loop would poll for the process lifetime and pop a
        // detail sheet minutes later when the user finally signs in.
        let waitDeadline = Date().addingTimeInterval(8)
        while !appState.isAuthenticated, !Task.isCancelled, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Cancelled (view re-keyed / disappeared): leave the signal
        // armed so the restarted task can still act on it instead of
        // silently dropping the Siri request.
        guard !Task.isCancelled else { return }
        guard appState.isAuthenticated, let user = appState.activeUser else {
            appState.requestContinueWatching = false
            return
        }

        let response = try? await dependencies.jellyfinLibraryService.getResumeItems(
            userID: user.id,
            mediaType: "Video",
            limit: 1
        )
        guard !Task.isCancelled else { return }
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
        // Cancelled (re-keyed / view disappeared): don't consume the
        // pending id; the restarted task picks it up with full time.
        guard !Task.isCancelled else { return }
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
        PlayerModalDismisser.dismissActive(logPrefix: "[AppRouter]")
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
        guard !Task.isCancelled else { return }
        deepLinkItem = item
        // Hold the overlay a beat past the fullScreenCover binding
        // flip so the cover's slide-in fully obscures the underlying
        // view before we fade our black overlay out. The pending id is
        // cleared LAST: this task is keyed on it, so nilling it earlier
        // cancelled ourselves at the next suspension point and the
        // 300 ms hold never actually happened (the stale-view flash
        // this overlay exists to mask was back).
        try? await Task.sleep(for: .milliseconds(300))
        appState.isResolvingDeepLink = false
        appState.pendingDeepLinkItemID = nil
    }

    /// Records the current tvOS user identifier so the scenePhase
    /// observer can detect a subsequent user change. Called from
    /// every entry point that does a full performRestore.
    private func markTVUserResolved() {
        let id = TVUserContext.currentUserID
        tvUserLogger.notice("markTVUserResolved: tvUserID=\(id ?? "nil", privacy: .public)")
        lastResolvedTVUserID = id
        lastResolvedTVUserIDSet = true
    }

    private func restoreSession() async {
        tvUserLogger.notice("restoreSession ENTER. tvUserID=\(TVUserContext.currentUserID ?? "nil", privacy: .public)")
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
        tvUserLogger.notice("performRestore ENTER. tvUserID=\(TVUserContext.currentUserID ?? "nil", privacy: .public) isAuth=\(appState.isAuthenticated, privacy: .public) pickerServer=\(launchPickerServer?.id ?? "nil", privacy: .public)")
        defer {
            tvUserLogger.notice("performRestore EXIT. isAuth=\(appState.isAuthenticated, privacy: .public) activeUser=\(appState.activeUser?.id ?? "nil", privacy: .public) activeServer=\(appState.activeServer?.id ?? "nil", privacy: .public) pickerServer=\(launchPickerServer?.id ?? "nil", privacy: .public)")
        }
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

        // The restore policy itself (keychain pointer repair,
        // default-server promotion, migrations, multi-profile launch
        // routing) lives in SessionRestorer; this view only maps its
        // outcome onto AppState + the picker state it owns.
        let outcome = SessionRestorer(dependencies: dependencies).restore()
        let syncSeerr: Bool
        switch outcome {
        case .authenticated(let server, let user):
            appState.setAuthenticated(server: server, user: user)
            Task { await refreshActiveUserPolicy(expectedUserID: user.id) }
            syncSeerr = true
        case .picker(let server, let wantsSeerr):
            launchPickerServer = server
            syncSeerr = wantsSeerr
        case .discovery:
            syncSeerr = false
        }
        guard syncSeerr else { return }

        // Seerr restore, prefer the profile-scoped session when the
        // active user has one saved, fall back to the global
        // last-used entry so legacy (pre-0.3.0) Seerr logins still
        // come back on first upgrade. The restore → probe → keep-or-
        // drop policy (including the legacy bridge persist) lives in
        // syncSeerrSession. Runs AFTER the AppState flip above so
        // TabRootView mounts under the splash and starts its loads
        // concurrently with the Seerr probe.
        let seerrOutcome = await dependencies.syncSeerrSession(
            forJellyfinUserID: appState.activeUser?.id,
            jellyfinServerID: appState.activeServer?.id,
            allowLegacyFallback: true
        )
        if case .connected(let seerrServer, let seerrUser) = seerrOutcome {
            appState.setSeerrConnected(server: seerrServer, user: seerrUser)
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
