import Foundation
import Combine
import AetherEngine

extension PlayerViewModel {

    /// Live-specific load: open the Jellyfin tuner via PlaybackInfo, pick the
    /// infinite live MediaSource, prefer its HLS TranscodingUrl, and hand it
    /// to the engine with isLive + a 30-minute DVR window. Sets the tuner
    /// handle for teardown to release.
    func loadLiveStream() async throws {
        // liveProfile() forces a TS transcode (Container=ts, Protocol=http):
        // a live channel is unbounded, and MPEG-TS over HTTP is live-streamable
        // (progressive MP4 is not), which is what the engine's AVIO live path
        // consumes.
        let info = try await playbackService.getPlaybackInfo(
            itemID: item.id, userID: userID, profile: DirectPlayProfile.liveProfile())
        playSessionID = info.playSessionId
        guard let source = info.mediaSources.first else { throw PlayerEngineError.noSource }
        mediaSourceID = source.id
        activeLiveStreamID = source.liveStreamId
        // DIAG: what is the live source actually made of? Tells us whether
        // Jellyfin could DirectStream (codec copy / remux) instead of
        // re-encoding. Remove once the profile is tuned.
        let streamDesc = (source.mediaStreams ?? []).map {
            "\($0.type)/\($0.codec ?? "?")\($0.width != nil ? " \($0.width!)x\($0.height ?? 0)" : "")\($0.bitRate != nil ? " \($0.bitRate!/1000)kbps" : "")"
        }.joined(separator: ", ")
        print("[LiveSrc] container=\(source.container ?? "nil") directPlay=\(source.supportsDirectPlay ?? false) directStream=\(source.supportsDirectStream ?? false) transcoding=\(source.supportsTranscoding ?? false) streams=[\(streamDesc)]")

        // Live channels stream via the transcoding URL (TS over HTTP); fall
        // back to a remux stream URL only if the server gave none.
        let url: URL
        if let transcoding = source.transcodingUrl,
           let built = playbackService.buildTranscodeURL(relativePath: transcoding) {
            url = built
        } else if let built = playbackService.buildStreamURL(
            itemID: item.id, mediaSourceID: source.id, container: source.container, isStatic: false) {
            url = built
        } else {
            throw PlayerEngineError.noSource
        }

        observeLiveEdge()

        try await player.load(
            url: url,
            startPosition: nil,
            options: LoadOptions(
                suppressDisplayCriteria: false,
                matchContentEnabled: Self.matchDynamicRangeEnabled,
                panelIsInHDRMode: Self.panelIsInHDRMode,
                audioBridgeMode: preferences.audioBridgeMode,
                isLive: true,
                dvrWindowSeconds: 1800
            )
        )
    }

    /// Mirror the engine's live-edge publishers into @Observable fields for
    /// the DVR transport. Same no-polling Combine pattern as the VOD path.
    ///
    /// Call once per session. It does not clear prior subscriptions; that is
    /// safe because `cancellables` is wiped on teardown and on episode
    /// transitions, and startPlayback is single-shot per session. If a future
    /// switch-channel-without-teardown path reuses the same view model, clear
    /// the live subscriptions here first to avoid stacking duplicate sinks.
    func observeLiveEdge() {
        player.$seekableLiveRange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] range in self?.liveSeekableRange = range }
            .store(in: &cancellables)
        player.$isAtLiveEdge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] atEdge in self?.isAtLiveEdge = atEdge }
            .store(in: &cancellables)
        player.$behindLiveSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] behind in self?.behindLiveSeconds = behind }
            .store(in: &cancellables)

        // Live baseline for the DVR scrubber: map the playhead across the
        // current seekable window so `progress` (and thus the scrub-start
        // baseline + displayedProgress) reflect the position within the
        // window. Live duration is 0, so the VOD progress math in the main
        // $currentTime sink would otherwise pin progress to 0. That sink
        // skips its own progress write for live (see PlayerViewModel), so
        // this is the sole writer of `progress` during a live session.
        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self, self.isLiveSession, !self.isScrubbing else { return }
                guard let range = self.liveSeekableRange,
                      range.upperBound > range.lowerBound else { return }
                let span = range.upperBound - range.lowerBound
                let pos = time - range.lowerBound
                self.progress = Float(max(0, min(1, pos / span)))
            }
            .store(in: &cancellables)
    }

    /// Snap back to the live edge (return-to-live chip).
    func returnToLiveEdge() {
        Task { await player.seekToLiveEdge() }
    }

    /// Commit a live (DVR) scrub: map `scrubProgress` (0...1) across the
    /// current `liveSeekableRange` and seek, clamped to the window. Scrubbing
    /// fully right (>= 0.99) snaps to the live edge rather than seeking near
    /// it, so the right edge doubles as the return-to-live affordance in v1.
    func commitLiveScrub() {
        guard isScrubbing,
              let range = liveSeekableRange,
              range.upperBound > range.lowerBound else {
            isScrubbing = false
            return
        }
        let p = scrubProgress
        // Mirror the VOD commit: set progress to the scrub position before
        // clearing isScrubbing so displayedProgress does not flash back to
        // the pre-scrub value before the seek lands.
        progress = p
        isScrubbing = false
        scrubPreview.clear()

        if p >= 0.99 {
            returnToLiveEdge()
            scheduleControlsHide()
            return
        }

        let span = range.upperBound - range.lowerBound
        let target = min(
            max(range.lowerBound + Double(p) * span, range.lowerBound),
            range.upperBound
        )
        Task {
            await player.seek(to: target)
            scheduleControlsHide()
        }
    }

    /// Release the Jellyfin live tuner if one is open. Idempotent: reads and
    /// clears `activeLiveStreamID`, then fires a detached close so a slow
    /// server cannot stall teardown. Safe to call on any teardown route; a
    /// no-op for VOD (activeLiveStreamID is nil). The stop report also
    /// carries the liveStreamId, so this is a belt-and-suspenders safety net
    /// against a dropped report.
    func releaseLiveTunerIfNeeded() {
        guard let liveStreamID = activeLiveStreamID else { return }
        activeLiveStreamID = nil
        let svc = playbackService
        Task.detached {
            try? await svc.closeLiveStream(liveStreamID: liveStreamID)
        }
    }
}
