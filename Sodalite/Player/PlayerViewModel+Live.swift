import Foundation
import Combine
import AetherEngine

extension PlayerViewModel {

    /// Live-specific load: open the Jellyfin tuner via PlaybackInfo, pick the
    /// infinite live MediaSource, prefer its HLS TranscodingUrl, and hand it
    /// to the engine with isLive + a 30-minute DVR window. Sets the tuner
    /// handle for teardown to release.
    func loadLiveStream() async throws {
        let info = try await playbackService.getPlaybackInfo(
            itemID: item.id, userID: userID, profile: DirectPlayProfile.current())
        playSessionID = info.playSessionId
        guard let source = info.mediaSources.first else { throw PlayerEngineError.noSource }
        mediaSourceID = source.id
        activeLiveStreamID = source.liveStreamId

        // Live channels are delivered as HLS via TranscodingUrl; fall back to
        // a remux stream URL only if the server gave none.
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
    }

    /// Snap back to the live edge (return-to-live chip).
    func returnToLiveEdge() {
        Task { await player.seekToLiveEdge() }
    }
}
