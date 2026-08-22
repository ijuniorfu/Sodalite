import Foundation

/// Whether a failure is the kind worth asking the library about.
///
/// Only a session that FAILED TO START asks. Asking from a running session was built and dropped
/// (2026-08-20, measured on device): at the moment a *arr upgrade swaps the file, the library has removed
/// the old item and not yet added the new one, so there is nothing to continue on however early the
/// question is asked, and every attempt to be clever there traded an error screen for a hang.
enum ReplacedItemRecoveryTrigger {

    /// Preconditions, split out from the method so the combination is pinned by a test rather than by
    /// reading four guards in a row.
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
    func beginReplacedItemRecovery(onGiveUp: @escaping @MainActor () -> Void) -> Bool {
        // An episode resolves on series, season and episode number; a movie on its external ids. Anything
        // else (a trailer, a recording, a music item) has no axis worth guessing on and keeps its error.
        guard ReplacedItemRecoveryTrigger.canAsk(
            isLiveSession: isLiveSession,
            isTearingDown: isTearingDown,
            alreadyAsked: didAttemptReplacedItemRecovery,
            isEpisode: item.seriesId != nil && item.indexNumber != nil,
            isMovieWithItemService: item.type == .movie && itemService != nil
        ) else { return false }
        didAttemptReplacedItemRecovery = true
        // The spinner owns the screen while the library answers, so a successful recovery never flashes an
        // error the viewer has to read.
        hostLoadActive = true

        let stale = item
        // A load that ran on prefetched playback info is worth repeating without it: the file behind an
        // unchanged id can still be a new one.
        let ranOnPrefetchedInfo = !(cachedPlaybackInfo?.matching(stale.id)?.mediaSources.isEmpty ?? true)
        let resumeSeconds = carriedResumeSeconds(from: stale)

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
