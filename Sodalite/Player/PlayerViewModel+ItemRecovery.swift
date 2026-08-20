import Foundation
import AetherEngine

/// Why the library is being asked about the item, which decides what a fruitless answer costs.
enum ReplacedItemRecoveryReason {
    /// The session could not start, or the engine declared it dead. Nothing is on screen but an error, so
    /// a fruitless lookup paints the failure the caller was holding.
    case failure
    /// The reader is stalled with the session still up. A fruitless lookup says nothing here: the stall may
    /// still resolve, and the server probe may still call an outage, so this one stays silent.
    case stalledReader
}

/// Whether a failure is the kind worth asking the library about.
enum ReplacedItemRecoveryTrigger {

    /// Preconditions shared by both reasons. Split out from the method so the combination is pinned by a
    /// test rather than by reading four guards in a row.
    static func canAsk(
        isLiveSession: Bool,
        isTearingDown: Bool,
        alreadyAsked: Bool,
        isEpisode: Bool,
        isMovieWithItemService: Bool
    ) -> Bool {
        guard !isLiveSession, !isTearingDown, !alreadyAsked else { return false }
        return isEpisode || isMovieWithItemService
    }

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
    func beginReplacedItemRecovery(
        resumeAt seconds: Double?,
        reason: ReplacedItemRecoveryReason = .failure,
        onGiveUp: @escaping @MainActor () -> Void
    ) -> Bool {
        // An episode resolves on series, season and episode number; a movie on its external ids. Anything
        // else (a trailer, a recording, a music item) has no axis worth guessing on and keeps its error.
        guard ReplacedItemRecoveryTrigger.canAsk(
            isLiveSession: isLiveSession,
            isTearingDown: isTearingDown,
            alreadyAsked: reason == .failure ? didAttemptReplacedItemRecovery : didProbeStalledSource,
            isEpisode: item.seriesId != nil && item.indexNumber != nil,
            isMovieWithItemService: item.type == .movie && itemService != nil
        ) else { return false }

        switch reason {
        case .failure:
            didAttemptReplacedItemRecovery = true
            // The spinner owns the screen while the library answers, so a successful recovery never
            // flashes an error the viewer has to read. A stalled reader already has the spinner from the
            // engine phase and must not have it taken away by this lookup ending.
            hostLoadActive = true
        case .stalledReader:
            didProbeStalledSource = true
        }

        let stale = item
        // Only a load that actually ran on prefetched playback info is worth repeating without it. A
        // session that already produced frames fetched its own, so a death mid-stream is not that case.
        let ranOnPrefetchedInfo = !hasStartedPlaying && !(cachedPlaybackInfo?.mediaSources.isEmpty ?? true)
        let resumeSeconds = seconds ?? carriedResumeSeconds(from: stale)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let replacement = await ReplacedItemResolver.replacement(
                for: stale,
                episodes: self.playbackService,
                movies: self.itemService,
                userID: self.userID
            )
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
                LogTap.shared.note("[ItemRecovery] nothing replaced \(stale.id) (\(reason))")
                guard reason == .failure else { return }
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
