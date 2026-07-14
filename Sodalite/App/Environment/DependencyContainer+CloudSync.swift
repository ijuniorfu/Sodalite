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
            rewatchNextUp: HomeRowConfig.enableRewatchingNextUp(serverID: serverID)
        )
        let password = try? keychainService.loadString(for: KeychainKeys.jellyfinPassword(serverID: serverID))
        // Pre-feature installs stored the password without an owner entry. switchToUser
        // deletes the password on every profile switch, so an existing password can only
        // belong to the server's current user; backfill the owner from that.
        var passwordUserID = try? keychainService.loadString(for: KeychainKeys.jellyfinPasswordUserID(serverID: serverID))
        if password != nil, passwordUserID == nil {
            passwordUserID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: serverID))
        }
        return ServerSyncPayload(
            updatedAt: stamp,
            server: server,
            rememberedUsers: users,
            jellyfinPassword: password,
            passwordUserID: passwordUserID,
            seerrSessions: sessions,
            homeRows: homeRows
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

        // Snapshot before the blob overwrite: users dropped by the payload still
        // need their scoped Seerr sessions purged below.
        let previousUsers = listRememberedUsers(serverID: serverID)
        if let data = try? JSONEncoder().encode(payload.rememberedUsers) {
            try? keychainService.save(data, for: KeychainKeys.rememberedUsers(serverID: serverID))
        }

        if let password = payload.jellyfinPassword, let owner = payload.passwordUserID {
            try? keychainService.save(password, for: KeychainKeys.jellyfinPassword(serverID: serverID))
            try? keychainService.save(owner, for: KeychainKeys.jellyfinPasswordUserID(serverID: serverID))
        } else {
            try? keychainService.delete(for: KeychainKeys.jellyfinPassword(serverID: serverID))
            try? keychainService.delete(for: KeychainKeys.jellyfinPasswordUserID(serverID: serverID))
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
            NotificationCenter.default.post(name: .homeConfigDidChange, object: nil)
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
                networkBufferDepth: p.networkBufferDepth.rawValue
            ))
        case .appearance:
            let a = appearancePreferences
            return .appearance(AppearanceSettingsPayload(
                updatedAt: stamp,
                accentChoice: a.accentChoice.rawValue,
                showContentLogos: a.showContentLogos,
                continueWatchingImage: a.continueWatchingImage.rawValue,
                largeCards: a.largeCards,
                nowPlayingUsesSeriesPoster: a.nowPlayingUsesSeriesPoster
            ))
        case .auth:
            return .auth(AuthSettingsPayload(
                updatedAt: stamp,
                launchBehavior: authPreferences.launchBehavior.rawValue,
                defaultUserID: authPreferences.defaultUserID,
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
            store.playerRotationLocked = p.playerRotationLocked
            store.networkBufferDepth = PlaybackPreferences.NetworkBufferDepth(rawValue: p.networkBufferDepth) ?? store.networkBufferDepth
        case .appearance(let a):
            let store = appearancePreferences
            store.accentChoice = AppearancePreferences.AccentChoice(rawValue: a.accentChoice) ?? store.accentChoice
            store.showContentLogos = a.showContentLogos
            store.continueWatchingImage = AppearancePreferences.ContinueWatchingImage(rawValue: a.continueWatchingImage) ?? store.continueWatchingImage
            store.largeCards = a.largeCards
            store.nowPlayingUsesSeriesPoster = a.nowPlayingUsesSeriesPoster
        case .auth(let a):
            authPreferences.launchBehavior = AuthPreferences.LaunchBehavior(rawValue: a.launchBehavior) ?? authPreferences.launchBehavior
            authPreferences.defaultUserID = a.defaultUserID
            authPreferences.defaultServerID = a.defaultServerID
        case .seerrNotifications(let s):
            seerrNotificationPreferences.notifyPendingRequests = s.notifyPendingRequests
        case .parentalControls(let p):
            parentalControlsPreferences.protectedProfileIDs = Set(p.protectedProfileIDs)
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
