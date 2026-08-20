import Foundation
import AetherEngine

/// Whether a failure is the kind worth asking the library about.
enum ReplacedItemRecoveryTrigger {

    /// The host's request reached the server and the server answered with a status. Which status a
    /// vanished item earns is not fixed: it depends on the Jellyfin version and on the endpoint the
    /// request reached, so every answered status qualifies and the library list decides. Only failures
    /// that never reached a server (dead link, timeout, malformed response) say nothing about the item.
    static func serverAnswered(hostError: Error) -> Bool {
        switch hostError as? APIError {
        case .httpError, .unauthorized:
            return true
        case .serverUnreachable, .timeout, .networkError, .invalidURL, .invalidResponse, .decodingError, nil:
            return false
        }
    }

    /// The same question for a failure the engine typed: only the faces that carry an origin status.
    static func serverAnswered(engineFace: PlayerEngineErrorPresentation.Face) -> Bool {
        switch engineFace {
        case .streamNotFound, .streamRefused, .streamServerError:
            return true
        case .rateLimited, .dolbyVisionUnsupported, .liveChannelUnavailable, .engineMessage:
            return false
        }
    }
}

extension PlayerViewModel {

    /// A failure the server answered may be an episode the library replaced under this session: a Sonarr
    /// upgrade rewrites the file, Jellyfin mints a new id for the new path and drops the old one, and
    /// every id the app is still holding names an item the server no longer has. Ask the season what it
    /// lists now and continue on the item that took this one's place.
    ///
    /// Returns true once the question is out, in which case the caller must not paint an error: the
    /// spinner stays up and `onGiveUp` paints the failure if nothing was replaced after all.
    @discardableResult
    func beginReplacedItemRecovery(resumeAt seconds: Double?, onGiveUp: @escaping @MainActor () -> Void) -> Bool {
        guard !isLiveSession, !isTearingDown, !didAttemptReplacedItemRecovery else { return false }
        // Episodes only: series, season and episode number identify the new file without guessing. A
        // movie has no such axis, so a replaced movie keeps its error.
        guard item.seriesId != nil, item.indexNumber != nil else { return false }
        didAttemptReplacedItemRecovery = true

        let stale = item
        // Only a load that actually ran on prefetched playback info is worth repeating without it. A
        // session that already produced frames fetched its own, so a death mid-stream is not that case.
        let ranOnPrefetchedInfo = !hasStartedPlaying && !(cachedPlaybackInfo?.mediaSources.isEmpty ?? true)
        let resumeSeconds = seconds ?? carriedResumeSeconds(from: stale)
        hostLoadActive = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolver = ReplacedEpisodeResolver(service: self.playbackService, userID: self.userID)
            let replacement = await resolver.replacement(for: stale)
            guard !self.isTearingDown, self.item.id == stale.id else { return }

            if let replacement {
                LogTap.shared.note("[ItemRecovery] replaced \(stale.id) -> \(replacement.id)")
                self.item = replacement
                NotificationCenter.default.post(
                    name: .libraryItemDidReplace,
                    object: nil,
                    userInfo: [
                        LibraryItemReplacementKey.staleID: stale.id,
                        LibraryItemReplacementKey.item: replacement
                    ]
                )
                self.restartAfterItemRecovery(resumeAt: resumeSeconds)
            } else if ranOnPrefetchedInfo {
                // The id is still listed, so identity is not what broke. The prefetched PlaybackInfo
                // still describes whatever file sat there when the detail screen opened, so ask again.
                LogTap.shared.note("[ItemRecovery] \(stale.id) still listed, retrying without prefetched playback info")
                self.restartAfterItemRecovery(resumeAt: resumeSeconds)
            } else {
                LogTap.shared.note("[ItemRecovery] nothing replaced \(stale.id)")
                self.hostLoadActive = false
                onGiveUp()
            }
        }
        return true
    }

    /// The position a replaced item cannot carry itself: the new file is a new item, so its own userData
    /// starts at zero even though the viewer was in the middle of that episode.
    private func carriedResumeSeconds(from stale: JellyfinItem) -> Double? {
        guard !startFromBeginning,
              let ticks = stale.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks.ticksToSeconds
    }
}
