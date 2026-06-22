import Foundation
import Combine
import AetherEngine

extension PlayerViewModel {

    /// Live load: try the tuner's HLS upstream directly first (engine ingest, Jellyfin out of the data path), fall back to the Jellyfin-mediated path once per session. TS/static channels and those without a usable upstream URL go straight to the server path. Design: docs/superpowers/specs/2026-06-11-live-hls-ingest-direct-play-design.md.
    func loadLiveStream() async throws {
        // Stage-1 PlaybackInfo: copy ceiling + the tuner upstream URL (MediaSource.Path) for the direct attempt.
        let info = try await playbackService.getLivePlaybackInfo(
            itemID: item.id, userID: userID,
            profile: DirectPlayProfile.liveProfile(),
            maxStreamingBitrate: DirectPlayProfile.liveCopyCeilingBitrate)
        guard let source = info.mediaSources.first else { throw PlayerEngineError.noSource }

        // Direct eligibility: remux channel (TranscodingUrl present) whose Path is a real http(s) provider URL. TS/static channels have no TranscodingUrl and a Path pointing at Jellyfin's internal LiveStreamFiles, so they keep the server path.
        if !didAttemptLiveFallback,
           source.transcodingUrl != nil,
           let path = source.path,
           let upstream = URL(string: path),
           let scheme = upstream.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            // Reader created here so its terminalError is reachable in the catch fallback log.
            let reader = HLSLiveIngestReader(playlistURL: upstream)
            do {
                try await loadLiveDirect(info: info, source: source, upstream: upstream, reader: reader)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Once per session, fall back to the Jellyfin path; the direct attempt already closed (awaited) the stage-1 tuner, so the server path re-negotiates fresh.
                didAttemptLiveFallback = true
                usedDirectLivePath = false
                let detail = reader.terminalError.map { " ingest=\($0)" } ?? ""
                LogTap.shared.note("[LiveDirect] route=fallback reason=\(error)\(detail)")
                try await loadLiveStreamViaServer()
                return
            }
        } else {
            let route = source.transcodingUrl == nil ? "static" : "server"
            LogTap.shared.note("[LiveDirect] route=\(route)")
        }

        // Ineligible route (static/server): reuse the stage-1 tuner so it isn't leaked and the server path avoids a duplicate roundtrip.
        try await loadLiveStreamViaServer(reusing: (info: info, source: source))
    }

    /// Direct play: close the Jellyfin tuner first (single-connection providers must never see two concurrent connections), then hand the upstream playlist to the engine's HLS ingest.
    private func loadLiveDirect(
        info: PlaybackInfoResponse,
        source: PlaybackMediaSource,
        upstream: URL,
        reader: HLSLiveIngestReader
    ) async throws {
        if let tuner = source.liveStreamId {
            // Awaited (spec decision 3): single-connection providers must never see the Jellyfin tuner and our direct connection at once, and a straggling close must not race the fallback's freshly opened tuner. Bounded so a hung server can't stall the tune.
            let svc = playbackService
            enum CloseRace { case closed, timedOut }
            let outcome = try? await withThrowingTaskGroup(of: CloseRace.self) { group -> CloseRace? in
                group.addTask {
                    try await svc.closeLiveStream(liveStreamID: tuner)
                    return .closed
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    return .timedOut
                }
                let first = try await group.next()
                group.cancelAll()
                return first
            }
            if outcome != .closed {
                // Tuner keeps ingesting (writing LiveStreamFiles) until Jellyfin's inactivity cleanup reaps it; log so disk-growth reports are traceable.
                LogTap.shared.note("[LiveDirect] tuner close timed out, server will reap it")
            }
        }
        playSessionID = info.playSessionId
        mediaSourceID = source.id
        activeLiveStreamID = nil
        usedDirectLivePath = true
        LogTap.shared.note("[LiveDirect] route=direct upstream=\(upstream.absoluteString)")

        observeLiveEdge()
        try await player.load(
            source: .custom(reader, formatHint: "mpegts"),
            options: LoadOptions(
                suppressDisplayCriteria: false,
                matchContentEnabled: Self.matchDynamicRangeEnabled,
                panelIsInHDRMode: Self.panelIsInHDRMode,
                audioBridgeMode: preferences.audioBridgeMode,
                isLive: true,
                dvrWindowSeconds: 600,
                preserveASSMarkup: true
            )
        )

        let engine = player
        scrubPreview.configureLive(enabled: preferences.showScrubPreview) { [weak engine] seconds, maxWidth in
            await engine?.liveScrubThumbnail(atSessionSeconds: seconds, maxWidth: maxWidth)
        }
    }

    /// Jellyfin-mediated live load: open the tuner via PlaybackInfo, pick the infinite live MediaSource, prefer its HLS TranscodingUrl, hand it to the engine with isLive + a DVR window, and set the tuner handle for teardown.
    ///
    /// - Parameter prefetched: reuses a stage-1 PlaybackInfo from the router (avoids a second tuner + duplicate roundtrip); nil triggers a fresh negotiation.
    private func loadLiveStreamViaServer(
        reusing prefetched: (info: PlaybackInfoResponse, source: PlaybackMediaSource)? = nil
    ) async throws {
        // Engine-decode live: request a copy-TS source (liveProfile = Protocol=http, full codec list) and hand to AetherEngine like VOD. The engine demuxes the TS, dispatching h264/hevc to native AVPlayer loopback and MPEG-2/VC-1/MPEG-4 Part 2 to SW, so every codec plays with no re-encode. High copy ceiling (maxStreamingBitrate) keeps the server stream-copying rather than downscaling.
        var info: PlaybackInfoResponse
        var source: PlaybackMediaSource
        if let prefetched {
            info = prefetched.info
            source = prefetched.source
        } else {
            info = try await playbackService.getLivePlaybackInfo(
                itemID: item.id, userID: userID,
                profile: DirectPlayProfile.liveProfile(),
                maxStreamingBitrate: DirectPlayProfile.liveCopyCeilingBitrate)
            guard let first = info.mediaSources.first else { throw PlayerEngineError.noSource }
            source = first
        }

        // Two-stage bitrate negotiation: MaxStreamingBitrate is both copy threshold AND encoder target. For a codec NOT in liveProfile's copy list (VideoCodecNotSupported) the high ceiling becomes a 200 Mbps real-time encode target Jellyfin answers with HTTP 500 (device repro: "Infomercial"); re-request at a bounded encode cap, releasing the first probe's tuner.
        if Self.liveNeedsVideoReencode(transcodeReasons: source.transcodeReasons,
                                       transcodingURL: source.transcodingUrl)
            || Self.liveSourceVideoCodecUnknown(source) {
            let staleTuner = source.liveStreamId
            info = try await playbackService.getLivePlaybackInfo(
                itemID: item.id, userID: userID,
                profile: DirectPlayProfile.liveProfile(),
                maxStreamingBitrate: DirectPlayProfile.liveReencodeCapBitrate)
            guard let rebounded = info.mediaSources.first else { throw PlayerEngineError.noSource }
            source = rebounded
            if let staleTuner, staleTuner != source.liveStreamId {
                let svc = playbackService
                Task.detached { try? await svc.closeLiveStream(liveStreamID: staleTuner) }
            }
        }

        playSessionID = info.playSessionId
        mediaSourceID = source.id
        activeLiveStreamID = source.liveStreamId

        // Resolve the progressive TS URL the engine's AVIOReader consumes. Transcode/remux channels carry a TranscodingUrl; a DirectPlay/DirectStream source carries NONE, and bailing black-screened those channels (device repro: "ATV HD", directPlay=1), so the static stream URL is their pure-copy path.
        let tsURL: URL
        if let transcoding = source.transcodingUrl,
           let transcodeURL = playbackService.buildTranscodeURL(relativePath: transcoding) {
            tsURL = transcodeURL
        } else if source.supportsDirectStream == true || source.supportsDirectPlay == true,
                  let staticURL = playbackService.buildStreamURL(
                    itemID: item.id,
                    mediaSourceID: source.id,
                    container: "ts",
                    isStatic: true
                  ) {
            tsURL = staticURL
        } else {
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
                dvrWindowSeconds: 600,
                // Raw ASS event lines for the styled-subtitle path (ASSRenderCoordinator); only affects ASS/SSA content.
                preserveASSMarkup: true
            )
        )

        // Live scrub preview frames come from the engine's DVR segment cache (liveScrubThumbnail), not a FrameExtractor (live source is forward-only, FFmpeg has no network). Retune-safe: configureLive resets first.
        let engine = player
        scrubPreview.configureLive(enabled: preferences.showScrubPreview) { [weak engine] seconds, maxWidth in
            await engine?.liveScrubThumbnail(atSessionSeconds: seconds, maxWidth: maxWidth)
        }
    }

    /// Mirror the engine's live-edge publishers into @Observable fields for the DVR transport (no-polling Combine, same as VOD). Single-shot per session via the `hasLiveEdgeObservers` latch; `cancellables` is wiped on teardown/episode-transition, and a live retune re-runs loadLiveStream on the SAME view model.
    func observeLiveEdge() {
        guard !hasLiveEdgeObservers else { return }
        hasLiveEdgeObservers = true
        player.clock.$seekableLiveRange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] range in self?.liveSeekableRange = range }
            .store(in: &cancellables)
        player.clock.$isAtLiveEdge
            .receive(on: DispatchQueue.main)
            .sink { [weak self] atEdge in self?.isAtLiveEdge = atEdge }
            .store(in: &cancellables)
        player.clock.$behindLiveSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] behind in self?.behindLiveSeconds = behind }
            .store(in: &cancellables)

        // DVR scrubber baseline: map the playhead across the seekable window into `progress` (live duration is 0, so VOD progress math would pin it to 0; the main $currentTime sink skips its progress write for live, making this the sole writer during a live session).
        player.clock.$currentTime
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
        // Mirror VOD commit: set progress before clearing isScrubbing so displayedProgress doesn't flash back to the pre-scrub value before the seek lands.
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

    /// Feed the scrub preview during a live scrub: map the scrub fraction
    /// across the DVR window to absolute session seconds (the same math
    /// commitLiveScrub uses for the seek).
    func updateLiveScrubPreview() {
        guard let range = liveSeekableRange, range.upperBound > range.lowerBound else { return }
        let span = range.upperBound - range.lowerBound
        // Mirror commitLiveScrub: >= 0.99 snaps to live edge, so the preview matches where the commit lands.
        let p = scrubProgress >= 0.99 ? 1.0 : Double(scrubProgress)
        scrubPreview.update(targetSeconds: range.lowerBound + p * span)
    }

    /// Engine `liveSourceReset` entry: a connection drop made the server restart its stream from byte 0 (Jellyfin transcode respawn), so the engine parked. Recovery is full re-negotiation (fresh PlaybackInfo, new PlaySessionId, transcode anchored at live edge, new engine load). Loop-guarded: one retune in flight, minimum spacing, bounded per session.
    func handleLiveSourceReset() {
        guard isLiveSession else {
            LogTap.shared.note("[Live] retune skipped: not a live session")
            return
        }
        guard !liveRetuneInFlight else {
            // A second reset rides on the in-flight retune; logged so a STUCK latch (hung loadLiveStream) is visible rather than silently swallowing all future recovery.
            LogTap.shared.note("[Live] retune skipped: already in flight (count=\(liveRetuneCount))")
            return
        }
        let tooSoon = lastLiveRetuneAt.map { Date().timeIntervalSince($0) < 20 } ?? false
        guard liveRetuneCount < 3, !tooSoon else {
            // Every retune fails (server replays from byte 0, or transcode keeps dying); stop cycling tuners and surface. Generalized message since this gate also terminates the mid-session engine-error retune path.
            LogTap.shared.note(
                "[Live] retune EXHAUSTED (count=\(liveRetuneCount) tooSoon=\(tooSoon)); surfacing error"
            )
            isLoading = false
            setEnginePlaybackError(message: String(
                localized: "player.error.liveRetuneExhausted",
                defaultValue: "The live stream keeps failing. Please try the channel again."
            ))
            return
        }
        // A direct-ingest source that died mid-watch is suspect; retune via the Jellyfin path, not the dead upstream. Next manual zap tries direct again (flags reset per startPlayback).
        if usedDirectLivePath {
            didAttemptLiveFallback = true
            usedDirectLivePath = false
            LogTap.shared.note("[LiveDirect] route=fallback reason=mid_session_source_reset")
        } else {
            LogTap.shared.note("[Live] retune starting (count=\(liveRetuneCount + 1), already on server route)")
        }

        liveRetuneInFlight = true
        liveRetuneCount += 1
        lastLiveRetuneAt = Date()
        isLoading = true
        Task { [weak self] in
            guard let self else { return }
            await self.retuneLiveStream()
            self.liveRetuneInFlight = false
        }
    }

    /// Close the dead session, then re-run the live load. Engine `load` supersedes the parked session internally; a CancellationError means a newer load (channel zap) took over mid-retune.
    func retuneLiveStream() async {
        // Close the dead session server-side BEFORE opening the new one: stop report (with tuner handle), explicit transcode kill (orphan ffmpeg writes a growing stream.ts and fills server disk), tuner release.
        let deadTuner = activeLiveStreamID
        let deadSession = playSessionID
        await reportStop(liveStreamID: deadTuner)
        if let deadSession {
            let svc = playbackService
            Task.detached { try? await svc.stopActiveEncodings(playSessionID: deadSession) }
        }
        hasReportedStart = false
        releaseLiveTunerIfNeeded()
        do {
            try await loadLiveStream()
            await reportStart()
        } catch is CancellationError {
            // Superseded by a newer load; nothing to clean up.
        } catch {
            isLoading = false
            setEnginePlaybackError(message: error.localizedDescription)
        }
    }

    /// Release the Jellyfin live tuner if open. Idempotent: clears `activeLiveStreamID` then fires a detached close so a slow server can't stall teardown. No-op for VOD. Belt-and-suspenders against a dropped stop report (which also carries liveStreamId).
    func releaseLiveTunerIfNeeded() {
        guard let liveStreamID = activeLiveStreamID else { return }
        activeLiveStreamID = nil
        let svc = playbackService
        Task.detached {
            try? await svc.closeLiveStream(liveStreamID: liveStreamID)
        }
    }

    /// Whether the server's probe failed to identify the source's video codec (no streams, or a video stream without a codec). Jellyfin can't stream-copy what it couldn't identify, so the high copy ceiling silently becomes a 200 Mbps ENCODE target (HTTP 500); route through the bounded re-encode cap up front, where ffmpeg's runtime probe may still read it.
    static func liveSourceVideoCodecUnknown(_ source: PlaybackMediaSource) -> Bool {
        guard let video = source.mediaStreams?.first(where: { $0.type == .video })
        else { return true }
        return (video.codec ?? "").isEmpty
    }

    /// Whether the live source needs a real VIDEO re-encode (codec not in liveProfile's copy list). Checks BOTH the MediaSource field and the TranscodingUrl query reasons, since Jellyfin populates the field unreliably (empty for some channels even when the URL carries VideoCodecNotSupported).
    static func liveNeedsVideoReencode(transcodeReasons: [String]?, transcodingURL: String?) -> Bool {
        if (transcodeReasons ?? []).contains("VideoCodecNotSupported") { return true }
        guard let t = transcodingURL,
              let comps = URLComponents(string: t.hasPrefix("http") ? t : "http://x" + t),
              let reasons = comps.queryItems?.first(where: { $0.name == "TranscodeReasons" })?.value
        else { return false }
        return reasons.split(separator: ",").map(String.init).contains("VideoCodecNotSupported")
    }

}
