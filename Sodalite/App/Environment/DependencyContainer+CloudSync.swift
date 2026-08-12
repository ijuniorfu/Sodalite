import Foundation

/// Bridge between the sync payloads and the app's real stores (keychain +
/// preference stores). Collect reads local state into a payload; apply writes a
/// payload back. Apply paths run with isApplyingCloudChanges set so the
/// mutation hooks in DependencyContainer do not echo the change back to CloudKit.
extension DependencyContainer {

    // MARK: Servers

    func collectServerPayload(serverID: String, stamp: Date) -> ServerSyncPayload? {
        guard let server = listKnownServers().first(where: { $0.id == serverID }) else { return nil }
        let users = listRememberedUsers(serverID: serverID)
        let sessions: [RememberedSeerrSession] = users.compactMap { user in
            guard let data = try? keychainService.loadData(
                for: KeychainKeys.rememberedSeerr(jellyfinServerID: serverID, jellyfinUserID: user.id)
            ) else { return nil }
            return try? JSONDecoder().decode(RememberedSeerrSession.self, from: data)
        }
        let homeRows = HomeRowsSyncState(
            configsJSON: HomeRowConfig.rawConfigData(serverID: serverID),
            mergeCWNextUp: HomeRowConfig.mergeContinueWatchingNextUp(serverID: serverID),
            rewatchNextUp: HomeRowConfig.enableRewatchingNextUp(serverID: serverID),
            collectionGrouping: HomeRowConfig.collectionGrouping(serverID: serverID).rawValue
        )
        // One password per profile. The active user is included explicitly: they may have signed in
        // moments ago and not be in the remembered list yet.
        var passwordUserIDs = Set(users.map(\.id))
        let activeUserID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))
        if let activeUserID { passwordUserIDs.insert(activeUserID) }
        var passwords: [String: String] = [:]
        for userID in passwordUserIDs {
            if let password = try? keychainService.loadString(
                for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: userID)
            ) {
                passwords[userID] = password
            }
        }
        // Legacy fields for devices that predate the per-user layout: give them the active
        // profile's password, which is the one their single slot used to hold anyway.
        let legacyUserID = activeUserID.flatMap { passwords[$0] != nil ? $0 : nil } ?? passwords.keys.sorted().first
        return ServerSyncPayload(
            updatedAt: stamp,
            server: server,
            rememberedUsers: users,
            jellyfinPassword: legacyUserID.flatMap { passwords[$0] },
            passwordUserID: legacyUserID,
            jellyfinPasswords: passwords.isEmpty ? nil : passwords,
            seerrSessions: sessions,
            homeRows: homeRows,
            defaultUserID: authPreferences.defaultUserID(serverID: serverID)
        )
    }

    func applyServerPayload(_ payload: ServerSyncPayload) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        let serverID = payload.server.id

        // Upsert in place; a remote add appends so it never hijacks local MRU order.
        var servers = listKnownServers()
        if let idx = servers.firstIndex(where: { $0.id == serverID }) {
            servers[idx] = payload.server
        } else {
            servers.append(payload.server)
        }
        if let data = try? JSONEncoder().encode(servers) {
            try? keychainService.save(data, for: KeychainKeys.knownServers)
        }

        // A synced URL edit to the active server must reach the live client without a relaunch
        // (an Apple TV picks up edits made on the iPhone). scheduleRouteResolve only reads + probes,
        // so it is safe inside the apply path and does not echo a cloud write back.
        if payload.server.id == activeServer?.id {
            // The in-memory copy has to move with the keychain: a profile switch persists whatever
            // AppState holds through addServer, so leaving it on the pre-sync snapshot wrote the old
            // URL slots straight back out again (Sodalite#45). id-guarded inside AppState.
            appState?.updateActiveServer(payload.server)
            scheduleRouteResolve()
        }

        // Snapshot before the blob overwrite: users dropped by the payload still
        // need their scoped Seerr sessions purged below.
        let previousUsers = listRememberedUsers(serverID: serverID)
        if let data = try? JSONEncoder().encode(payload.rememberedUsers) {
            try? keychainService.save(data, for: KeychainKeys.rememberedUsers(serverID: serverID))
        }

        // Additive on purpose: a password is device-local knowledge (a device signed in with Quick
        // Connect or the picker never has one), so "the payload carries none" means "the sender does
        // not know it", not "there is none". Deleting on that reading let one passwordless device
        // strip the password from every other one. Only a local logout or forgetUser removes them.
        var incomingPasswords = payload.jellyfinPasswords ?? [:]
        if let password = payload.jellyfinPassword, let owner = payload.passwordUserID {
            incomingPasswords[owner] = password
        }
        for (userID, password) in incomingPasswords {
            try? keychainService.save(
                password,
                for: KeychainKeys.jellyfinPassword(serverID: serverID, userID: userID)
            )
        }

        // Seerr sessions: payload is authoritative for this server's users. Sweep the
        // union of previous + payload users so a user dropped from the payload does not
        // leave a dangling rememberedSeerr_* entry behind.
        let sessionUserIDs = Set(payload.seerrSessions.map(\.jellyfinUserID))
        let sweepUserIDs = Set(previousUsers.map(\.id)).union(payload.rememberedUsers.map(\.id))
        for userID in sweepUserIDs where !sessionUserIDs.contains(userID) {
            forgetRememberedSeerr(forJellyfinUserID: userID, jellyfinServerID: serverID)
        }
        for session in payload.seerrSessions {
            if let data = try? JSONEncoder().encode(session) {
                try? keychainService.save(data, for: KeychainKeys.rememberedSeerr(
                    jellyfinServerID: serverID, jellyfinUserID: session.jellyfinUserID))
            }
        }

        if let homeRows = payload.homeRows {
            if let configs = homeRows.configsJSON {
                HomeRowConfig.setRawConfigData(configs, serverID: serverID)
            }
            HomeRowConfig.setMergeContinueWatchingNextUp(homeRows.mergeCWNextUp, serverID: serverID)
            HomeRowConfig.setEnableRewatchingNextUp(homeRows.rewatchNextUp, serverID: serverID)
            // Absent on payloads from builds before Sodalite#44; leave the local mode alone rather than resetting it to the server default.
            if let grouping = homeRows.collectionGrouping {
                HomeRowConfig.setCollectionGrouping(CollectionGrouping(storedValue: grouping), serverID: serverID)
            }
            NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
        }

        // Absent on payloads from builds that still kept the pin in the global auth store; leave the local pin alone rather than clearing it.
        if let defaultUserID = payload.defaultUserID {
            authPreferences.setDefaultUserID(defaultUserID, serverID: serverID)
        }
    }

    /// Remote record delete: same teardown as a local removeServer (successor
    /// promotion included), but suppressed so it does not echo back to CloudKit.
    func applyRemoteServerDeletion(serverID: String) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        try? removeServer(id: serverID)
    }

    // MARK: Settings stores

    func collectSettingsPayload(_ key: CloudSyncStoreKey, stamp: Date) -> SettingsSyncPayload {
        switch key {
        case .playback:
            let p = playbackPreferences
            return .playback(PlaybackSettingsPayload(
                updatedAt: stamp,
                autoplayNextEpisode: p.autoplayNextEpisode,
                autoSkipIntro: p.autoSkipIntro,
                autoSkipOutro: p.autoSkipOutro,
                nextEpisodeCountdownSeconds: p.nextEpisodeCountdownSeconds,
                skipIntervalSeconds: p.skipIntervalSeconds,
                preferredAudioLanguage: p.preferredAudioLanguage,
                preferredSubtitleLanguage: p.preferredSubtitleLanguage,
                autoSubtitleForForeignAudio: p.autoSubtitleForForeignAudio,
                styledASSSubtitles: p.styledASSSubtitles,
                subtitleFontSize: p.subtitleFontSize.rawValue,
                subtitleColor: p.subtitleColor.rawValue,
                subtitleBackground: p.subtitleBackground.rawValue,
                subtitleDelaySeconds: p.subtitleDelaySeconds,
                subtitleVerticalPosition: p.subtitleVerticalPosition.rawValue,
                subtitleFont: p.subtitleFont.rawValue,
                subtitleWeight: p.subtitleWeight.rawValue,
                pictureMode: p.pictureMode.rawValue,
                showStatsForNerds: p.showStatsForNerds,
                showEngineDiagnostics: p.showEngineDiagnostics,
                showDiagnosticOverlay: p.showDiagnosticOverlay,
                focusDiagnosticOverlayOnDV: p.focusDiagnosticOverlayOnDV,
                preferLosslessAudioBridge: p.preferLosslessAudioBridge,
                showScrubPreview: p.showScrubPreview,
                preferServerTrickplay: p.preferServerTrickplay,
                playerRotationLocked: p.playerRotationLocked,
                networkBufferDepth: p.networkBufferDepth.rawValue,
                rememberTrackSelections: p.rememberTrackSelections,
                autoForcedSubtitles: p.autoForcedSubtitles,
                selectTogglesPlayback: p.selectTogglesPlayback,
                instantSkipSeek: p.instantSkipSeek,
                autoSkipRecap: p.autoSkipRecap,
                subtitlesOnSkipBack: p.subtitlesOnSkipBack
            ))
        case .appearance:
            let a = appearancePreferences
            return .appearance(AppearanceSettingsPayload(
                updatedAt: stamp,
                accentChoice: a.storedAccentRawValue,
                backgroundStyle: a.storedBackgroundRawValue,
                showContentLogos: a.showContentLogos,
                continueWatchingImage: a.continueWatchingImage.rawValue,
                largeCards: a.largeCards,
                nowPlayingUsesSeriesPoster: a.nowPlayingUsesSeriesPoster,
                spoilerProtectionEnabled: a.spoilerProtectionEnabled,
                spoilerHideEpisodes: a.spoilerHideEpisodes,
                spoilerHideMovies: a.spoilerHideMovies,
                hiddenTabs: a.hiddenTabs.map(\.rawValue).sorted()
            ))
        case .auth:
            return .auth(AuthSettingsPayload(
                updatedAt: stamp,
                launchBehavior: authPreferences.launchBehavior.rawValue,
                // Legacy mirror for devices still on a build without the per-server pin: the default server's is the one they would have used.
                defaultUserID: authPreferences.defaultServerID
                    .flatMap { authPreferences.defaultUserID(serverID: $0) },
                defaultServerID: authPreferences.defaultServerID
            ))
        case .seerrNotifications:
            return .seerrNotifications(SeerrNotificationSettingsPayload(
                updatedAt: stamp,
                notifyPendingRequests: seerrNotificationPreferences.notifyPendingRequests
            ))
        case .parentalControls:
            return .parentalControls(ParentalControlsSettingsPayload(
                updatedAt: stamp,
                protectedProfileIDs: parentalControlsPreferences.protectedProfileIDs.sorted()
            ))
        case .trackMemory:
            return .trackMemory(TrackMemoryPayload(
                updatedAt: stamp,
                entries: trackSelectionMemory.entries
            ))
        case .spoilerReveals:
            return .spoilerReveals(SpoilerRevealPayload(
                updatedAt: stamp,
                entries: spoilerRevealMemory.entries
            ))
        }
    }

    func applySettingsPayload(_ payload: SettingsSyncPayload) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        switch payload {
        case .playback(let p):
            let store = playbackPreferences
            store.autoplayNextEpisode = p.autoplayNextEpisode
            store.autoSkipIntro = p.autoSkipIntro
            store.autoSkipOutro = p.autoSkipOutro
            store.nextEpisodeCountdownSeconds = p.nextEpisodeCountdownSeconds
            store.skipIntervalSeconds = p.skipIntervalSeconds
            store.preferredAudioLanguage = p.preferredAudioLanguage
            store.preferredSubtitleLanguage = p.preferredSubtitleLanguage
            store.autoSubtitleForForeignAudio = p.autoSubtitleForForeignAudio
            store.styledASSSubtitles = p.styledASSSubtitles
            store.subtitleFontSize = PlaybackPreferences.SubtitleFontSize(rawValue: p.subtitleFontSize) ?? store.subtitleFontSize
            store.subtitleColor = PlaybackPreferences.SubtitleColor(rawValue: p.subtitleColor) ?? store.subtitleColor
            store.subtitleBackground = PlaybackPreferences.SubtitleBackground(rawValue: p.subtitleBackground) ?? store.subtitleBackground
            store.subtitleDelaySeconds = p.subtitleDelaySeconds
            store.subtitleVerticalPosition = PlaybackPreferences.SubtitleVerticalPosition(rawValue: p.subtitleVerticalPosition) ?? store.subtitleVerticalPosition
            store.subtitleFont = PlaybackPreferences.SubtitleFont(rawValue: p.subtitleFont) ?? store.subtitleFont
            store.subtitleWeight = PlaybackPreferences.SubtitleWeight(rawValue: p.subtitleWeight) ?? store.subtitleWeight
            store.pictureMode = PlaybackPreferences.PictureMode(rawValue: p.pictureMode) ?? store.pictureMode
            store.showStatsForNerds = p.showStatsForNerds
            store.showEngineDiagnostics = p.showEngineDiagnostics
            store.showDiagnosticOverlay = p.showDiagnosticOverlay
            store.focusDiagnosticOverlayOnDV = p.focusDiagnosticOverlayOnDV
            store.preferLosslessAudioBridge = p.preferLosslessAudioBridge
            store.showScrubPreview = p.showScrubPreview
            store.preferServerTrickplay = p.preferServerTrickplay
            // Absent on payloads from builds before these fields existed; leave the local
            // value alone rather than resetting it to a default.
            if let rotationLocked = p.playerRotationLocked { store.playerRotationLocked = rotationLocked }
            if let depth = p.networkBufferDepth {
                store.networkBufferDepth = PlaybackPreferences.NetworkBufferDepth(rawValue: depth) ?? store.networkBufferDepth
            }
            if let remember = p.rememberTrackSelections { store.rememberTrackSelections = remember }
            if let forced = p.autoForcedSubtitles { store.autoForcedSubtitles = forced }
            if let selectToggles = p.selectTogglesPlayback { store.selectTogglesPlayback = selectToggles }
            if let instantSkip = p.instantSkipSeek { store.instantSkipSeek = instantSkip }
            if let autoSkipRecap = p.autoSkipRecap { store.autoSkipRecap = autoSkipRecap }
            if let skipBackSubs = p.subtitlesOnSkipBack { store.subtitlesOnSkipBack = skipBackSubs }
        case .appearance(let a):
            let store = appearancePreferences
            if let accentChoice = AppearancePreferences.AccentChoice(rawValue: a.accentChoice) {
                store.accentChoice = accentChoice
            }
            if let backgroundStyle = BackgroundStyle(rawValue: a.backgroundStyle) {
                store.backgroundStyle = backgroundStyle
            }
            store.showContentLogos = a.showContentLogos
            store.continueWatchingImage = AppearancePreferences.ContinueWatchingImage(rawValue: a.continueWatchingImage) ?? store.continueWatchingImage
            store.largeCards = a.largeCards
            store.nowPlayingUsesSeriesPoster = a.nowPlayingUsesSeriesPoster
            store.spoilerProtectionEnabled = a.spoilerProtectionEnabled
            store.spoilerHideEpisodes = a.spoilerHideEpisodes
            store.spoilerHideMovies = a.spoilerHideMovies
            // Absent field = sender predates tab visibility, so it carries no opinion; applying an empty set would silently unhide the receiver's tabs (Sodalite#62).
            if let tabs = a.hiddenTabs {
                store.hiddenTabs = Set(tabs.compactMap(AppTab.init(rawValue:)).filter(\.isHideable))
            }
        case .auth(let a):
            authPreferences.launchBehavior = AuthPreferences.LaunchBehavior(rawValue: a.launchBehavior) ?? authPreferences.launchBehavior
            // a.defaultUserID is the retired global pin, deliberately not applied: it carries no server, so applying it would pin the wrong server's profile. The per-server value rides the server record.
            authPreferences.defaultServerID = a.defaultServerID
        case .seerrNotifications(let s):
            seerrNotificationPreferences.notifyPendingRequests = s.notifyPendingRequests
        case .parentalControls(let p):
            parentalControlsPreferences.protectedProfileIDs = Set(p.protectedProfileIDs)
        case .trackMemory(let t):
            trackSelectionMemory.replaceAll(t.entries)
        case .spoilerReveals(let s):
            spoilerRevealMemory.replaceAll(s.entries)
        }
    }

    // MARK: Security (Guardian PIN)

    func collectSecurityPayload(stamp: Date) -> SecuritySyncPayload? {
        guard let data = try? keychainService.loadData(for: KeychainKeys.guardianPINBlob),
              let blob = try? JSONDecoder().decode(GuardianPINCrypto.Blob.self, from: data)
        else { return nil }
        return SecuritySyncPayload(updatedAt: stamp, pinBlob: blob)
    }

    func applySecurityPayload(_ payload: SecuritySyncPayload) {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        // Write the blob directly (saveGuardianPIN would re-derive from a plain
        // PIN we do not have). The local throttle is deliberately untouched.
        if let data = try? JSONEncoder().encode(payload.pinBlob) {
            try? keychainService.save(data, for: KeychainKeys.guardianPINBlob)
        }
    }

    func applyRemoteSecurityDeletion() {
        isApplyingCloudChanges = true
        defer { isApplyingCloudChanges = false }
        try? clearGuardianPIN()
    }
}
