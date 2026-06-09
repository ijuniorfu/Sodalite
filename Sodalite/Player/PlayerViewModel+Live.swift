import Foundation
import Combine
import AetherEngine

extension PlayerViewModel {

    /// Live-specific load: open the Jellyfin tuner via PlaybackInfo, pick the
    /// infinite live MediaSource, prefer its HLS TranscodingUrl, and hand it
    /// to the engine with isLive + a 30-minute DVR window. Sets the tuner
    /// handle for teardown to release.
    func loadLiveStream() async throws {
        // Engine-decode live: request a copy-TS source (liveProfile uses
        // Protocol=http, full codec list) and hand it to AetherEngine exactly
        // like VOD. The engine demuxes the TS and dispatches h264/hevc to the
        // native AVPlayer loopback and MPEG-2 / VC-1 / MPEG-4 Part 2 to the SW
        // decoder, so every live codec plays with no server re-encode. The high
        // copy ceiling (maxStreamingBitrate) keeps the server stream-copying the
        // source bitstream rather than downscaling it.
        let info = try await playbackService.getLivePlaybackInfo(
            itemID: item.id, userID: userID,
            profile: DirectPlayProfile.liveProfile(),
            maxStreamingBitrate: DirectPlayProfile.liveCopyCeilingBitrate)
        guard let source = info.mediaSources.first else { throw PlayerEngineError.noSource }

        playSessionID = info.playSessionId
        mediaSourceID = source.id
        activeLiveStreamID = source.liveStreamId

        // The copy-TS TranscodingUrl points at the progressive TS stream the
        // engine's AVIOReader consumes. The tuner lifecycle (open via
        // AutoOpenLiveStream above, close on teardown) is unchanged.
        guard let transcoding = source.transcodingUrl,
              let tsURL = playbackService.buildTranscodeURL(relativePath: transcoding) else {
            throw PlayerEngineError.noSource
        }

        observeLiveEdge()

        try await player.load(
            url: tsURL,
            startPosition: nil,
            options: LoadOptions(
                suppressDisplayCriteria: false,
                matchContentEnabled: Self.matchDynamicRangeEnabled,
                panelIsInHDRMode: Self.panelIsInHDRMode,
                audioBridgeMode: preferences.audioBridgeMode,
                isLive: true,
                dvrWindowSeconds: 600
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
