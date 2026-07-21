import SwiftUI
import os.log

private let tvUserLogger = Logger(subsystem: "de.superuser404.Sodalite", category: "tvUser")

struct AppRouter: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies
    @Environment(\.scenePhase) private var scenePhase

    /// Guards the initial restore + splash against SwiftUI re-firing `.task` on AppRouter disappear (e.g. player modal on screen), which would otherwise re-show the splash.
    @State private var hasRestored = false
    /// Same `.task` re-fire guard for the server-switch handler: records the last serverDidSwitch value handled so a player dismissal doesn't re-run the probe + Seerr restore.
    @State private var lastHandledServerSwitch = 0
    /// tvOS user id as of the last performRestore. Dormant on the current SDK (currentUserIdentifier always nil); kept so multi-user reactivates if Apple revives the API.
    @State private var lastResolvedTVUserID: String?
    @State private var lastResolvedTVUserIDSet = false

    /// Non-nil while the launch-time profile picker is armed. Picking a profile flips isAuthenticated=true which hides it.
    @State private var launchPickerServer: JellyfinServer?

    /// ContinuousClock (keeps counting through device sleep) instant of the last .background
    /// entry; consumed on return to .active by maybeRequestProfileReprompt (issue #41).
    @State private var lastBackgroundedAt: ContinuousClock.Instant?
    /// Drives the who's-watching reprompt cover.
    @State private var showProfileReprompt = false

    /// JellyfinItem fetched for an incoming deep link; drives the fullScreenCover (non-nil = sheet shown).
    @State private var deepLinkItem: JellyfinItem?

    /// Drives the WhatsNew fullScreenCover after the splash on a release-boundary launch; dismiss callback stamps the version seen.
    @State private var showWhatsNew = false

    /// Drives the NowPlaying fullScreenCover off the coordinator's nowPlayingPresentationRequest bump.
    @State private var showNowPlaying = false

    #if os(iOS)
    @State private var pathObserver = NetworkPathObserver()
    #endif

    /// (server, user) identity of the active session. Background music is scoped to it and must stop when it
    /// changes: server switch, same-server profile switch (switchToUser, which does NOT bump serverDidSwitch),
    /// active-server removal, logout (activeServer/activeUser -> nil), and tvOS-user change all land here.
    private var activeSessionIdentity: String {
        "\(appState.activeServer?.id ?? "none")|\(appState.activeUser?.id ?? "none")"
    }

    /// Edge-triggered active flag: keys a `.task` so the monitor refreshes on foreground, not on every phase change.
    private var scenePhaseIsActive: Bool { scenePhase == .active }

    /// Refresh the pending-approval count and, on iOS, keep the app-icon badge + notifications in sync.
    private func refreshPending() async {
        #if os(iOS)
        await PendingRequestsSync.refreshAndSync(
            monitor: dependencies.pendingRequestsMonitor,
            preferences: dependencies.seerrNotificationPreferences
        )
        #else
        await dependencies.pendingRequestsMonitor.refresh()
        #endif
    }

    var body: some View {
        ZStack {
            if appState.isAuthenticated {
                TabRootView()
            } else if let server = launchPickerServer {
                LaunchProfilePickerView(server: server)
            } else {
                ServerDiscoveryView()
            }

            // Now-Playing is surfaced in the Music tab + track tap (not a global bar, which covered detail action buttons); both bump the coordinator's presentation request, observed below.

            // Splash overlays until restore finishes AND the minimum display time elapses, then cross-fades out (avoids a jarring snap on a <100ms restore).
            if appState.isLoading {
                SplashView()
                    .transition(.opacity)
            }

            // Masks the stale detail view (~1-2s) between deep-link player dismiss and the new fullScreenCover sliding in.
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
        // Keep the Catalog pending-requests badge fresh: recompute when the app comes forward, when the
        // Seerr connection flips, and on the admin-queue change signal. iOS/iPadOS badge; inert on tvOS.
        .task(id: scenePhaseIsActive) {
            if scenePhaseIsActive {
                await refreshPending()
                await dependencies.cloudSync?.fetchNow()
                #if os(iOS)
                dependencies.scheduleRouteResolve()
                #endif
            }
        }
        .task(id: appState.isSeerrConnected) {
            if appState.isSeerrConnected {
                await refreshPending()
            } else {
                dependencies.pendingRequestsMonitor.reset()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seerrPendingRequestsShouldRefresh)) { _ in
            Task { await refreshPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seerrRequestDidSubmit)) { _ in
            Task { await refreshPending() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidApplyChanges)) { _ in
            // Fresh install: the initial restore finishes on an empty keychain and
            // routes to discovery before the first cloud-sync fetch lands. Re-run
            // the restore when synced data arrives so the profile picker appears
            // without an app relaunch.
            guard !appState.isAuthenticated, !appState.isLoading else { return }
            Task { await restoreSession() }
        }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            // Queue the next background poll when leaving the foreground, only while opted in.
            if phase == .background, dependencies.seerrNotificationPreferences.notifyPendingRequests {
                PendingRequestsBackgroundRefresh.schedule()
            }
        }
        #endif
        .task {
            guard !hasRestored else { return }
            hasRestored = true
            await restoreSession()
        }
        .task {
            #if os(iOS)
            pathObserver.onPathChange = { dependencies.scheduleRouteResolve() }
            pathObserver.start()
            #endif
        }
        .task(id: appState.pendingDeepLinkItemID) {
            await resolvePendingDeepLink()
        }
        .task(id: appState.requestContinueWatching) {
            await resolveContinueWatchingRequest()
        }
        .task(id: scenePhase) {
            tvUserLogger.notice("scenePhase task fired: phase=\(String(describing: scenePhase), privacy: .public) tvUserID=\(TVUserContext.currentUserID ?? "nil", privacy: .public) last=\(lastResolvedTVUserID ?? "nil", privacy: .public) lastSet=\(lastResolvedTVUserIDSet, privacy: .public) isAuth=\(appState.isAuthenticated, privacy: .public) pickerServer=\(launchPickerServer?.id ?? "nil", privacy: .public)")
            if scenePhase == .background {
                lastBackgroundedAt = ContinuousClock().now
            }
            // Only react to .active; inactive/background need no tvOS-user re-resolve.
            guard scenePhase == .active else {
                tvUserLogger.notice("scenePhase: skip (not active)")
                return
            }
            // Consume on every .active entry: a stale instant must never survive into a later task re-fire.
            let backgroundedAt = lastBackgroundedAt
            lastBackgroundedAt = nil
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
                // Drop the previous tvOS user's live Seerr identity (else the new user browses as them, since performRestore only touches Seerr on a fresh restore). Client-only detach, NOT clearSeerrSession(): the keychain entries must survive for switch-back.
                appState.disconnectSeerr()
                dependencies.detachSeerrClient()
                launchPickerServer = nil
                showProfileReprompt = false
                markTVUserResolved()
                await performRestore()
            } else {
                maybeRequestProfileReprompt(backgroundedAt: backgroundedAt)
                tvUserLogger.notice("scenePhase: same tvUser. Cheap resolveTVUserContext.")
                // Same tvOS user: cheap re-resolve in case the mapping was edited in Settings on another scene.
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
            let handledSignal = appState.serverDidSwitch
            lastHandledServerSwitch = handledSignal
            // Latch rollback on cancellation (player cover presenting mid-probe cancels AFTER the latch); else the reappear re-fire is guarded away and the switch is left half-applied.
            defer {
                if Task.isCancelled, lastHandledServerSwitch == handledSignal {
                    lastHandledServerSwitch = handledSignal - 1
                }
            }
            // Capture the probe target ONCE: re-reading activeServer after the await could observe a NEWER switch's pointer and authenticate a mixed identity.
            let probedServer = dependencies.activeServer
            do {
                let user = try await dependencies.probeActiveUser()
                // Superseded mid-probe (newer switch re-keyed the task): stale result must not touch AppState/Seerr.
                guard !Task.isCancelled else { return }
                if let user, let server = probedServer {
                    appState.setAuthenticated(server: server, user: user)
                    // Restore the per-(server,user) Seerr session so Catalog reflects the new identity.
                    let outcome = await dependencies.syncSeerrSession(
                        forJellyfinUserID: user.id,
                        jellyfinServerID: server.id
                    )
                    guard !Task.isCancelled else { return }
                    if case .connected(let seerrServer, let seerrUser) = outcome {
                        appState.setSeerrConnected(server: seerrServer, user: seerrUser)
                        dependencies.scheduleRouteResolve()
                    } else {
                        appState.disconnectSeerr()
                    }
                } else {
                    // Token expired, no remembered user, or the active server was removed with no
                    // successor: route to the picker for the new active server, or fall through to
                    // ServerDiscoveryView when there is none. Assign unconditionally so a nil
                    // activeServer clears any stale picker instead of stranding a deleted server.
                    launchPickerServer = dependencies.activeServer
                    appState.isAuthenticated = false
                }
            } catch {
                // Cancellation is never a verdict on the target server: a superseded switch cancels this task and URLSession throws, which we must not misread as a transport failure and roll back the user's NEWER pick.
                guard !Task.isCancelled else { return }
                // Avoid rollback loops: if appState already holds the active server (just rolled back, probe still failing), let the failure stand for the next user action to surface.
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
            #if os(iOS)
            // tvOS dismisses this deep-link cover via the Menu button; iOS needs a touch
            // close. Floating overlay (not a toolbar) because detail views hide the nav bar.
            .overlay(alignment: .topLeading) {
                Button {
                    deepLinkItem = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.hierarchical)
                        .padding()
                }
                .buttonStyle(.plain)
            }
            #endif
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView(onClose: { showNowPlaying = false })
        }
        .onChange(of: dependencies.musicPlaybackCoordinator.nowPlayingPresentationRequest) { _, _ in
            showNowPlaying = true
        }
        // Background music is scoped to the active (server, user) session; stop it whenever that identity
        // changes (server switch, profile switch, active-server removal, logout). No-op when nothing is playing.
        .onChange(of: activeSessionIdentity) { _, _ in
            if dependencies.musicPlaybackCoordinator.currentItem != nil {
                dependencies.musicPlaybackCoordinator.stop()
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
        .fullScreenCover(item: Binding(
            get: { showProfileReprompt ? nil : dependencies.parentalGate.activeRequest },
            set: { if $0 == nil { dependencies.parentalGate.resolve(false) } }
        )) { request in
            PINEntryView(mode: .unlock(reason: request.reason)) { unlocked in
                dependencies.parentalGate.resolve(unlocked)
            }
        }
        .fullScreenCover(isPresented: $showProfileReprompt) {
            if let server = appState.activeServer {
                LaunchProfilePickerView(
                    server: server,
                    context: .reprompt,
                    onFinished: { showProfileReprompt = false }
                )
                // The AppRouter-level PIN cover can't stack on this cover (one cover per host view),
                // so the gate presents from inside while the reprompt is up.
                .fullScreenCover(item: Binding(
                    get: { dependencies.parentalGate.activeRequest },
                    set: { if $0 == nil { dependencies.parentalGate.resolve(false) } }
                )) { request in
                    PINEntryView(mode: .unlock(reason: request.reason)) { unlocked in
                        dependencies.parentalGate.resolve(unlocked)
                    }
                }
            }
        }
        .onChange(of: appState.isLoading) { _, isLoading in
            // Splash finished: fire What's-New on a release-boundary crossing. isAuthenticated lets the prefs layer tell a fresh install (don't pester) from a pre-Changelog upgrade (0.3.2 and earlier never wrote lastSeenVersion).
            guard !isLoading else { return }
            if ChangelogPreferences.shouldShowOnLaunch(isExistingUser: appState.isAuthenticated) {
                showWhatsNew = true
            } else {
                ChangelogPreferences.bootstrapIfNeeded()
            }
        }
    }

    /// Promotes the (server, profile) tuple pinned to the current tvOS user (mapping wins over defaultServerID, the more specific signal). Runs atop performRestore + on scene-foreground. No-op without multi-user.
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
            // SECURITY (parental controls): ONLY profile-activation path not behind the Guardian-PIN gate. Dormant now (currentUserID always nil, guard above returned). If Apple revives multi-user, gate this switch with dependencies.parentalGate before switchToUser or it bypasses the lock.
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
            // switchServer's serverDidSwitch bump drives the probe + setAuthenticated path.
            return
        }

        // Keychain already matches (resume for a tvOS user whose state was never wiped, e.g. brief switch away and back). switchServer won't fire, so force-flip AppState authenticated, else the body lingers on the prior session's view (often ServerDiscoveryView).
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

    /// Feeds the active user's first Resume item through the deep-link channel. Triggered by ContinueWatchingIntent; the intent stays trivial to respect tvOS-Siri's "no async work" voice-invocation policy.
    private func resolveContinueWatchingRequest() async {
        guard appState.requestContinueWatching else { return }

        // Cold-launch wait (Siri may hand control before restoreSession finishes), 8s cap so a fresh install / picker doesn't poll for the process lifetime and pop a sheet minutes later.
        let waitDeadline = Date().addingTimeInterval(8)
        while !appState.isAuthenticated, !Task.isCancelled, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Cancelled (re-keyed/disappeared): leave the signal armed so the restarted task still acts on it.
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

    /// Waits for auth, fetches the item, triggers the fullScreenCover. Clears the pending id last so a repeat tap on the same TopShelf cell re-fires.
    private func resolvePendingDeepLink() async {
        guard let id = appState.pendingDeepLinkItemID else {
            appState.isResolvingDeepLink = false
            return
        }
        // Cold-launch race: URL arrives before restoreSession finishes. Wait, 8s cap, since a missing-token state can leave isAuthenticated false at the picker and an unbounded wait would lock the user behind our overlay.
        let waitDeadline = Date().addingTimeInterval(8)
        while !appState.isAuthenticated, !Task.isCancelled, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Cancelled (re-keyed/disappeared): don't consume the pending id; the restarted task picks it up with full time.
        guard !Task.isCancelled else { return }
        guard appState.isAuthenticated, let user = appState.activeUser else {
            // Couldn't restore in time: drop the pending link + overlay so the user can interact with picker/discovery.
            appState.pendingDeepLinkItemID = nil
            appState.isResolvingDeepLink = false
            return
        }
        // Dismiss any active player before the new sheet (TopShelf often fires over a backgrounded paused player, else its modal stays on top of the new cover). Two-step: (1) bump requestPlayerDismissal so detail views flip showPlayer (keeps the binding path consistent on return); (2) walk the modal chain to dismiss PlayerHostController directly, since binding-driven dismiss proved unreliable across scene-foreground.
        // A deep link is deliberate navigation: drop the reprompt cover (continue as current profile)
        // and cancel any PIN challenge started from it, else its continuation later runs a stale switch.
        if showProfileReprompt {
            showProfileReprompt = false
            if dependencies.parentalGate.activeRequest != nil {
                dependencies.parentalGate.resolve(false)
            }
        }
        appState.requestPlayerDismissal &+= 1
        PlayerModalDismisser.dismissActive(logPrefix: "[AppRouter]")
        // Let UIKit finish the dismiss before the new fullScreenCover, else it races and SwiftUI warns "presenting from a VC that is being dismissed" or the modal never lands.
        try? await Task.sleep(for: .milliseconds(250))

        let item = try? await dependencies.jellyfinItemService.getItemDetail(
            userID: user.id,
            itemID: id
        )
        guard !Task.isCancelled else { return }
        deepLinkItem = item
        // Hold the overlay past the cover binding flip so the slide-in fully obscures the view before we fade out. Pending id cleared LAST: this task is keyed on it, so nilling earlier self-cancels at the next suspension and the 300ms hold never happens (stale-view flash returns).
        try? await Task.sleep(for: .milliseconds(300))
        appState.isResolvingDeepLink = false
        appState.pendingDeepLinkItemID = nil
    }

    /// Records the current tvOS user id so the scenePhase observer can detect a later change. Called from every full-performRestore entry point.
    private func markTVUserResolved() {
        let id = TVUserContext.currentUserID
        tvUserLogger.notice("markTVUserResolved: tvUserID=\(id ?? "nil", privacy: .public)")
        lastResolvedTVUserID = id
        lastResolvedTVUserIDSet = true
    }

    /// Caller consumes lastBackgroundedAt on every .active entry (a player dismissal re-fires the
    /// scenePhase task while still .active, and must not re-prompt); this only decides whether to
    /// arm the cover.
    private func maybeRequestProfileReprompt(backgroundedAt: ContinuousClock.Instant?) {
        guard let backgroundedAt else { return }
        // Never arm over a sibling cover (one fullScreenCover per host view) or a deep link in flight.
        guard deepLinkItem == nil, !showNowPlaying, !showWhatsNew,
              appState.pendingDeepLinkItemID == nil, !appState.isResolvingDeepLink
        else { return }
        guard let server = appState.activeServer else { return }
        let should = ProfileRepromptPolicy.shouldReprompt(
            elapsed: backgroundedAt.duration(to: ContinuousClock().now),
            interval: dependencies.authPreferences.profileReprompt,
            launchBehavior: dependencies.authPreferences.launchBehavior,
            isAuthenticated: appState.isAuthenticated,
            rememberedCount: dependencies.listRememberedUsers(serverID: server.id).count,
            isPlayerActive: PlayerModalPresence.isPlayerActive,
            tvUserChanged: false
        )
        if should { showProfileReprompt = true }
    }

    private func restoreSession() async {
        tvUserLogger.notice("restoreSession ENTER. tvUserID=\(TVUserContext.currentUserID ?? "nil", privacy: .public)")
        markTVUserResolved()
        appState.isLoading = true
        let splashStart = Date()

        // Fresh install: give the first iCloud fetch a bounded head start so a
        // synced household lands on the profile picker instead of discovery.
        if dependencies.listKnownServers().isEmpty,
           dependencies.cloudSync?.isEnabled == true {
            appState.isCloudSyncProbing = true
            await dependencies.cloudSync?.waitForInitialSync(timeout: 6)
            appState.isCloudSyncProbing = false
        }

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
        // Fire-and-forget: StoreKit is independent of the Jellyfin restore and shouldn't block the splash; isSupporter starts cached and flips live.
        Task { @MainActor in
            await dependencies.storeKitService.refreshSupporterStatus()
            await dependencies.storeKitService.loadProducts()
        }

        // Promote the current tvOS user's (server, profile) mapping (wins over any user-pinned default).
        await resolveTVUserContext()

        // Restore policy (pointer repair, default-server promotion, migrations, launch routing) lives in SessionRestorer; this view only maps the outcome onto AppState + picker state.
        let outcome = SessionRestorer(env: dependencies).restore()
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

        // Seerr restore (policy in syncSeerrSession), with legacy fallback for pre-0.3.0 logins. Runs AFTER the AppState flip so TabRootView mounts under the splash and loads concurrently with the probe.
        let seerrOutcome = await dependencies.syncSeerrSession(
            forJellyfinUserID: appState.activeUser?.id,
            jellyfinServerID: appState.activeServer?.id,
            allowLegacyFallback: true
        )
        if case .connected(let seerrServer, let seerrUser) = seerrOutcome {
            appState.setSeerrConnected(server: seerrServer, user: seerrUser)
            dependencies.scheduleRouteResolve()
        }
    }

    /// Refreshes the active user's Policy block via /Users/Me for the canDeleteContent permission gate (keychain-bootstrapped users have policy: nil, else the gated UI stays hidden until logout/login). `expectedUserID` discards the result if a racing profile switch changed the active user.
    private func refreshActiveUserPolicy(expectedUserID: String) async {
        guard let me = try? await dependencies.jellyfinAuthService.getCurrentUser(),
              me.id == expectedUserID,
              appState.activeUser?.id == expectedUserID
        else { return }
        appState.updateActiveUserPolicy(me.policy)
    }
}
