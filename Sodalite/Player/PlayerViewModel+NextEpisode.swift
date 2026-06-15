import Foundation
import AetherEngine

extension PlayerViewModel {

    func checkForNextEpisode() {
        let dur = effectiveDuration
        let remaining = dur - playbackTime
        guard dur > 0, remaining > 0, !hasFetchedNextEpisode else { return }

        // If the server gave us an outro marker (Jellyfin 10.10+ or the
        // intro-skipper plugin picked it up), start the next-episode
        // countdown as soon as the outro begins, that's usually where
        // credits roll and the episode is effectively over. Otherwise
        // fall back to the hardcoded 30 s-before-end threshold.
        let shouldFetch: Bool
        if let outro = outroSegment {
            // outro.startSeconds is absolute source time; compare against
            // sourceTime, not the AVPlayer clock (playbackTime).
            shouldFetch = player.sourceTime >= outro.startSeconds
        } else {
            shouldFetch = remaining < 30
        }
        guard shouldFetch else { return }

        // Shuffle / play queue: the next item is the next entry in the
        // queue, resolved synchronously with no series fetch. Must run
        // before the seriesId guard below, queue items are often movies
        // and carry no seriesId. When the queue is exhausted nextEpisode
        // stays nil and the engine's .idle handler dismisses the player.
        if isQueuePlayback {
            hasFetchedNextEpisode = true
            let nextIdx = queueIndex + 1
            if playQueue.indices.contains(nextIdx) {
                nextEpisode = playQueue[nextIdx]
            }
            return
        }

        guard item.seriesId != nil else { return }

        hasFetchedNextEpisode = true
        Task { await fetchNextEpisode() }
    }

    private func fetchNextEpisode() async {
        guard let seriesID = item.seriesId else { return }

        // Capture identifiers up front so anything we hand to the
        // server is a snapshot of the episode we're playing right
        // now, even if `item` mutates underneath us mid-await.
        let currentID = item.id
        let currentIndex = item.indexNumber
        let currentSeasonID = item.seasonId

        // Strict physical ordering, deliberately NOT Jellyfin's NextUp
        // endpoint. NextUp returns the next *unwatched* episode across the
        // whole series, so a season that already has some watched episodes
        // gets skipped entirely (e.g. S1E5 -> S3E1, jumping over a
        // partly-watched S2). The auto-advance overlay must always move to
        // the physically next episode: next index in the current season,
        // then the first episode of the next season.
        guard let currentSeasonID, let currentIndex else { return }

        do {
            // 1. Next episode within the current season: lowest
            // indexNumber strictly greater than the one we're playing.
            let episodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: currentSeasonID, userID: userID
            )
            if let candidate = episodes
                .filter({ $0.id != currentID })
                .filter({ ($0.indexNumber ?? -1) > currentIndex })
                .min(by: { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }) {
                // The user may have switched episodes via the picker
                // while this fetch was in flight; a stale result would
                // seed the OLD episode's successor and an early outro
                // could auto-advance to the wrong episode.
                guard item.id == currentID else { return }
                nextEpisode = candidate
                return
            }

            // 2. End of the season: roll over to the first episode of the
            // next season, ordered by season indexNumber. Specials
            // (season 0) sort below season 1, so picking the lowest season
            // index strictly greater than the current one never lands on
            // Specials after a finale, S1 finale advances to S2E1.
            let seasons = try await playbackService.getSeasons(
                seriesID: seriesID, userID: userID
            )
            guard let currentSeasonIndex = seasons
                .first(where: { $0.id == currentSeasonID })?.indexNumber,
                  let nextSeason = seasons
                .filter({ ($0.indexNumber ?? -1) > currentSeasonIndex })
                .min(by: { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) })
            else { return }

            let nextSeasonEpisodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: nextSeason.id, userID: userID
            )
            if let firstEpisode = nextSeasonEpisodes
                .min(by: { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }) {
                guard item.id == currentID else { return }
                nextEpisode = firstEpisode
            }
        } catch {
            #if DEBUG
            print("[NextEpisode] Fetch failed: \(error)")
            #endif
        }
    }

    /// Starts the auto-advance timer. `from` defaults to 10 s, that's
    /// the outro-based flow where we've got minutes of credits to burn
    /// through. The no-outro fallback passes the actual remaining
    /// seconds so the countdown hits 0 exactly at playback end.
    func startNextEpisodeCountdown(from seconds: Int = 10) {
        // If autoplay is disabled, still show the overlay (so the user
        // can pick next manually) but skip the timer that auto-transitions.
        guard preferences.autoplayNextEpisode else {
            isCountdownActive = false
            nextEpisodeCountdown = 0
            return
        }

        nextEpisodeCountdown = max(1, seconds)
        isCountdownActive = true
        nextEpisodeTimer?.cancel()
        LogTap.shared.note("[NextEp] countdown_start from=\(nextEpisodeCountdown)s nextId=\(nextEpisode?.id ?? "nil")")
        // [weak self]: a dismissed view model must not be kept alive
        // for the countdown's remainder (the engine outlives the VM,
        // the timer must not).
        nextEpisodeTimer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.nextEpisodeCountdown > 0 else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.nextEpisodeCountdown -= 1
            }
            guard !Task.isCancelled, self != nil else { return }
            LogTap.shared.note("[NextEp] countdown_fired")
            // Launch in a NEW task, if we called playNextEpisode() directly,
            // cancelling nextEpisodeTimer would cancel the playback startup
            // (CancellationError in player.load → "abgebrochen").
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
        }
    }

    func playNextEpisode() async {
        guard let next = nextEpisode else {
            LogTap.shared.note("[NextEp] playNextEpisode: bailing, nextEpisode is nil")
            return
        }
        // Second latch behind the timer cancellation in stopPlayback:
        // a countdown that fires into a torn-down session must never
        // load the next episode on the shared engine behind a
        // dismissed player (startPlayback resets isTearingDown at
        // entry, so this is the last line of defense).
        guard !isTearingDown else {
            LogTap.shared.note("[NextEp] playNextEpisode: bailing, session is tearing down")
            return
        }
        LogTap.shared.note("[NextEp] playNextEpisode enter: from=\(item.id) to=\(next.id)")
        // Queue playback: the item we're about to load is
        // playQueue[queueIndex + 1]; advance the cursor so the next
        // checkForNextEpisode seeds from the entry after it. resetSessionState
        // deliberately leaves playQueue / queueIndex untouched.
        if isQueuePlayback {
            queueIndex += 1
        }
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false

        // Stop current
        stopProgressReporting()
        cancellables.removeAll()

        // Fire-and-forget the stop report so a slow/flaky Jellyfin response
        // can't stall the transition. reportStop()'s 30 s URLRequest timeout
        // would otherwise leave the user staring at a hidden overlay with
        // no spinner if the server hiccups at the session boundary.
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: currentPositionTicks,
            liveStreamId: nil
        )
        let svc = playbackService
        Task {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
                LogTap.shared.note("[NextEp] report_stop_done (background)")
            } catch {
                LogTap.shared.note("[NextEp] report_stop_failed (background): \(error.localizedDescription)")
            }
        }

        // Do NOT call player.stop() here. A full stop tears down the
        // engine's native AVPlayer; the next startPlayback would build a
        // fresh one, and AVKit fails to re-register its system Now-Playing
        // session against a swapped player, blanking the iPhone Control
        // Center widget (issue #15). startPlayback -> engine.load(newURL)
        // reloads in place, preserving the AVPlayer instance across the
        // seam so Control Center keeps its metadata.
        LogTap.shared.note("[NextEp] reload_in_place (no engine stop)")

        resetSessionState(switchingTo: next)

        // Start new
        LogTap.shared.note("[NextEp] start_playback_enter id=\(item.id)")
        await startPlayback()
        LogTap.shared.note("[NextEp] start_playback_exit error=\(errorMessage ?? "nil") isPlaying=\(isPlaying)")
    }

    /// Shared per-session reset used by both episode-switch paths
    /// (auto-advance + season picker). One owner on purpose: the two
    /// inline copies had already drifted once (a stray player.stop()
    /// in the picker path, contradicting the issue-#15 AVPlayer-reuse
    /// design both copies documented).
    private func resetSessionState(switchingTo newItem: JellyfinItem) {
        item = newItem
        startFromBeginning = true
        cachedPlaybackInfo = nil
        errorMessage = nil
        videoFormat = .sdr
        subtitleCues = []
        subtitleStreams = []
        activeSubtitleIndex = nil
        activeAudioIndex = nil
        // This path bypasses teardown() for AVPlayer reuse (issue #15);
        // deactivate the ASS coordinator explicitly so the previous
        // episode's rendered script doesn't play over the next episode.
        deactivateASSRendering()
        // The remote subtitle-search overlay is part of the prior
        // session's UI; without this the stale overlay can stay mounted
        // over the next episode after a reload-in-place (issue #15 path).
        dismissSubtitleSearch()
        subtitleDeleteState = .hidden
        activeSubtitleCodec = nil
        nextEpisode = nil
        hasFetchedNextEpisode = false
        nextEpisodeCancelled = false
        nextEpisodeCountdown = 10
        isCountdownActive = false
        hasReportedStart = false
        hasStartedPlaying = false
        showControls = false
        isScrubbing = false
        controlsFocus = .progressBar
        trackDropdown = .none
        progress = 0
        playbackTime = 0
        resumePositionTicks = 0
        introSegment = nil
        outroSegment = nil
        isInsideIntro = false
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentOutro = false
        didSkipCurrentIntro = false
    }

    func cancelNextEpisode() {
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false
        isCountdownActive = false
        nextEpisodeCancelled = true
    }

    /// Tear down the overlay + countdown when the user scrubs back
    /// out of the end-window. Distinct from `cancelNextEpisode` in
    /// that it does NOT set `nextEpisodeCancelled = true` — the
    /// overlay should re-trigger naturally if the user plays forward
    /// back into the trigger window. Same fresh `nextEpisodeCountdown
    /// = 10` reset so the next show starts a clean countdown.
    func resetNextEpisodeOverlayState() {
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false
        isCountdownActive = false
        nextEpisodeCountdown = 10
    }

    // MARK: - Season Episode Picker

    /// Loads every episode of the currently-playing item's season,
    /// sorted by indexNumber, into `seasonEpisodes`. Used by the
    /// transport-bar episode picker. Silently no-ops for items
    /// without a series + season (movies, the rare orphan episode).
    func loadSeasonEpisodes() async {
        guard let seriesID = item.seriesId,
              let seasonID = item.seasonId else {
            seasonEpisodes = []
            return
        }
        do {
            let episodes = try await playbackService.getEpisodes(
                seriesID: seriesID, seasonID: seasonID, userID: userID
            )
            seasonEpisodes = episodes.sorted { ($0.indexNumber ?? .max) < ($1.indexNumber ?? .max) }
        } catch {
            #if DEBUG
            print("[SeasonPicker] Fetch failed: \(error)")
            #endif
            seasonEpisodes = []
        }
    }

    /// Switches playback to a specific episode in the loaded season
    /// list. Tearing down the current session and starting a fresh
    /// one mirrors the playNextEpisode flow exactly, same reset
    /// surface, same reportStop / reportStart cycle so Jellyfin's
    /// session tracking stays consistent. Bounds-checked against
    /// the current `seasonEpisodes` so a stale dropdown highlight
    /// can't crash by indexing into nothing.
    func selectEpisode(at index: Int) async {
        guard seasonEpisodes.indices.contains(index) else { return }
        let target = seasonEpisodes[index]
        guard target.id != item.id else { return }

        // Manually picking an episode from the season picker breaks the
        // shuffle queue: revert to ordinary series auto-advance from the
        // chosen episode onward.
        playQueue = []
        queueIndex = 0

        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        showNextEpisodeOverlay = false

        stopProgressReporting()
        cancellables.removeAll()

        // Fire-and-forget the stop report so a slow/flaky Jellyfin response
        // can't stall the transition. reportStop()'s 30 s URLRequest timeout
        // would otherwise leave the picker row unresponsive on a slow CDN
        // (DrHurt #12). Mirrors the same pattern playNextEpisode uses.
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: currentPositionTicks,
            liveStreamId: nil
        )
        let svc = playbackService
        Task {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
                LogTap.shared.note("[SeasonPicker] report_stop_done (background)")
            } catch {
                LogTap.shared.note("[SeasonPicker] report_stop_failed (background): \(error.localizedDescription)")
            }
        }

        // No player.stop() here, mirroring playNextEpisode: the engine
        // reloads in place via startPlayback -> engine.load(newURL),
        // preserving the AVPlayer instance so AVKit's system
        // Now-Playing session survives the seam (issue #15). The stop
        // this path used to carry was drift from before the reset
        // surface was shared.
        resetSessionState(switchingTo: target)

        await startPlayback()
    }
}
