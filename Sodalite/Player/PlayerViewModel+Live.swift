import Foundation
import Combine
import AetherEngine

extension PlayerViewModel {

    /// Live load: try the tuner's HLS upstream directly first (engine
    /// ingest, Jellyfin out of the data path), fall back to the
    /// Jellyfin-mediated path once per session. TS/static channels and
    /// channels without a usable upstream URL go straight to the server
    /// path. Design: docs/superpowers/specs/2026-06-11-live-hls-ingest-
    /// direct-play-design.md.
    func loadLiveStream() async throws {
        // Stage-1 PlaybackInfo: copy ceiling; also the source of the tuner
        // upstream URL (MediaSource.Path) for the direct attempt.
        let info = try await playbackService.getLivePlaybackInfo(
            itemID: item.id, userID: userID,
            profile: DirectPlayProfile.liveProfile(),
            maxStreamingBitrate: DirectPlayProfile.liveCopyCeilingBitrate)
        guard let source = info.mediaSources.first else { throw PlayerEngineError.noSource }

        // Direct eligibility: remux channel (TranscodingUrl present) whose
        // Path is a real http(s) provider URL. TS/static channels carry no
        // TranscodingUrl and their Path is Jellyfin's internal
        // LiveStreamFiles URL, not a provider; they keep the server path.
        if !didAttemptLiveFallback,
           source.transcodingUrl != nil,
           let path = source.path,
           let upstream = URL(string: path),
           let scheme = upstream.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            // Create the reader here so its terminalError is accessible
            // in the catch block for the fallback log.
            let reader = HLSLiveIngestReader(playlistURL: upstream)
            do {
                try await loadLiveDirect(info: info, source: source, upstream: upstream, reader: reader)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Once per session: fall back to the Jellyfin-mediated
                // path. The direct attempt already closed the stage-1
                // tuner (awaited); the server path re-negotiates fresh.
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

        // Ineligible route (static/server): reuse the stage-1 tuner so it
        // is not leaked and the server path avoids a duplicate roundtrip.
        try await loadLiveStreamViaServer(reusing: (info: info, source: source))
    }

    /// Direct play: close the Jellyfin tuner first (single-connection
    /// providers must never see two concurrent connections), then hand
    /// the upstream playlist to the engine's HLS ingest.
    private func loadLiveDirect(
        info: PlaybackInfoResponse,
        source: PlaybackMediaSource,
        upstream: URL,
        reader: HLSLiveIngestReader
    ) async throws {
        if let tuner = source.liveStreamId {
            // Awaited on purpose (spec decision 3): single-connection
            // providers must never see the Jellyfin tuner and our direct
            // connection concurrently, and a straggling close must not race
            // the fallback's freshly opened tuner. Bounded so a hung server
            // cannot stall the tune.
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
                // The tuner keeps ingesting (and writing LiveStreamFiles)
                // server-side until Jellyfin's inactivity cleanup reaps
                // it; surface that so disk-growth reports are traceable.
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

    /// Jellyfin-mediated live load: open the tuner via PlaybackInfo, pick the
    /// infinite live MediaSource, prefer its HLS TranscodingUrl, and hand it
    /// to the engine with isLive + a DVR window. Sets the tuner handle for
    /// teardown to release.
    ///
    /// Pass `prefetched` to reuse a stage-1 PlaybackInfo result that was
    /// already obtained by the router (avoids opening a second tuner and a
    /// duplicate roundtrip). When nil, a fresh negotiation is performed.
    private func loadLiveStreamViaServer(
        reusing prefetched: (info: PlaybackInfoResponse, source: PlaybackMediaSource)? = nil
    ) async throws {
        // Engine-decode live: request a copy-TS source (liveProfile uses
        // Protocol=http, full codec list) and hand it to AetherEngine exactly
        // like VOD. The engine demuxes the TS and dispatches h264/hevc to the
        // native AVPlayer loopback and MPEG-2 / VC-1 / MPEG-4 Part 2 to the SW
        // decoder, so every live codec plays with no server re-encode. The high
        // copy ceiling (maxStreamingBitrate) keeps the server stream-copying the
        // source bitstream rather than downscaling it.
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

        // Two-stage bitrate negotiation. The PlaybackInfo MaxStreamingBitrate
        // serves double duty: copy threshold AND encoder target. The high copy
        // ceiling keeps compatible codecs stream-copying, but for a channel
        // whose source codec is NOT in liveProfile's copy list
        // (VideoCodecNotSupported) it becomes a 200 Mbps real-time encode
        // target, which Jellyfin answers with HTTP 500 (device repro:
        // "Infomercial"). Re-request those at a bounded encode cap, releasing
        // the tuner the first probe opened.
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

        // Resolve the progressive TS URL the engine's AVIOReader consumes.
        // Transcode/remux channels carry a TranscodingUrl; a source the server
        // rates DirectPlay/DirectStream (container already ts, codecs in
        // profile) carries NONE, and bailing on it black-screened those
        // channels silently (device repro: "ATV HD", directPlay=1). For them
        // the static stream URL is the pure copy path.
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
                // Raw ASS event lines for the styled-subtitle path
                // (ASSRenderCoordinator). Only changes ASS/SSA cue
                // content; other subtitle codecs are unaffected.
                preserveASSMarkup: true
            )
        )

        // Live scrub preview: frames come from the engine's DVR segment
        // cache (liveScrubThumbnail), not a FrameExtractor over the source
        // URL (the live source is forward-only and FFmpeg has no network).
        // Same settings toggle as VOD. Retune re-runs this; configureLive
        // resets first, so that is idempotent.
        let engine = player
        scrubPreview.configureLive(enabled: preferences.showScrubPreview) { [weak engine] seconds, maxWidth in
            await engine?.liveScrubThumbnail(atSessionSeconds: seconds, maxWidth: maxWidth)
        }
    }

    /// Mirror the engine's live-edge publishers into @Observable fields for
    /// the DVR transport. Same no-polling Combine pattern as the VOD path.
    ///
    /// Call once per session. It does not clear prior subscriptions; that is
    /// safe because `cancellables` is wiped on teardown and on episode
    /// transitions, and startPlayback is single-shot per session. A live
    /// retune re-runs `loadLiveStream` on the SAME view model, so the
    /// `hasLiveEdgeObservers` latch keeps this single-shot there too.
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

        // Live baseline for the DVR scrubber: map the playhead across the
        // current seekable window so `progress` (and thus the scrub-start
        // baseline + displayedProgress) reflect the position within the
        // window. Live duration is 0, so the VOD progress math in the main
        // $currentTime sink would otherwise pin progress to 0. That sink
        // skips its own progress write for live (see PlayerViewModel), so
        // this is the sole writer of `progress` during a live session.
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

    /// Feed the scrub preview during a live scrub: map the scrub fraction
    /// across the DVR window to absolute session seconds (the same math
    /// commitLiveScrub uses for the seek).
    func updateLiveScrubPreview() {
        guard let range = liveSeekableRange, range.upperBound > range.lowerBound else { return }
        let span = range.upperBound - range.lowerBound
        // Mirror commitLiveScrub: >= 0.99 snaps to the live edge, so the
        // preview shows the frame the commit would actually land on.
        let p = scrubProgress >= 0.99 ? 1.0 : Double(scrubProgress)
        scrubPreview.update(targetSeconds: range.lowerBound + p * span)
    }

    /// Entry point for the engine's `liveSourceReset` event: after a
    /// connection drop the source server restarted its stream from the
    /// beginning (Jellyfin transcode respawn re-serving from byte 0), so the
    /// engine parked the session; reopening the same URL would replay the
    /// already-seen content again. Recovery is a full re-negotiation: fresh
    /// PlaybackInfo (new PlaySessionId, new transcode anchored at the live
    /// edge) and a new engine load. Guarded against loops: one retune in
    /// flight at a time, minimum spacing, bounded per session.
    func handleLiveSourceReset() {
        guard isLiveSession, !liveRetuneInFlight else { return }
        let tooSoon = lastLiveRetuneAt.map { Date().timeIntervalSince($0) < 20 } ?? false
        guard liveRetuneCount < 3, !tooSoon else {
            // The stream fails on every retune (server replays from
            // byte 0, or the transcode keeps dying); stop cycling
            // tuners and surface it instead. Message is generalized
            // because this gate also terminates the mid-session
            // engine-error retune path, not just source resets.
            isLoading = false
            setEnginePlaybackError(message: String(
                localized: "player.error.liveRetuneExhausted",
                defaultValue: "The live stream keeps failing. Please try the channel again."
            ))
            return
        }
        // A direct-ingest source that died mid-watch is suspect; retune via
        // the Jellyfin path instead of the same dead upstream. The next
        // manual zap tries direct again (flags reset per startPlayback).
        if usedDirectLivePath {
            didAttemptLiveFallback = true
            usedDirectLivePath = false
            LogTap.shared.note("[LiveDirect] route=fallback reason=mid_session_source_reset")
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

    /// Close the dead play session, then re-run the live load. The engine's
    /// `load` supersedes the parked session internally; a CancellationError
    /// means a newer load (channel zap) took over mid-retune and owns the
    /// session now.
    func retuneLiveStream() async {
        // Close the dead session server-side BEFORE opening the new one:
        // stop report (with the tuner handle), explicit transcode kill
        // (the old ffmpeg writes a growing stream.ts until killed; an
        // orphan fills the server disk), tuner release.
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
            // Superseded by a newer load; nothing to clean up here.
        } catch {
            isLoading = false
            setEnginePlaybackError(message: error.localizedDescription)
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

    /// Whether the probed live source needs a real VIDEO re-encode (its codec
    /// is not in liveProfile's copy list). Checks BOTH the MediaSource field
    /// and the reasons embedded in the TranscodingUrl query: Jellyfin
    /// populates the field unreliably (empty for some channels even when the
    /// URL carries TranscodeReasons=...,VideoCodecNotSupported).
    /// Whether the server's probe failed to identify the source's video
    /// codec (no media streams, or a video stream without a codec).
    /// Jellyfin cannot stream-copy what it could not identify, so for
    /// these channels the high copy ceiling silently becomes a 200 Mbps
    /// real-time ENCODE target, which the server answers with HTTP 500.
    /// Route them through the bounded re-encode cap up front: ffmpeg's
    /// own runtime probe is more patient than the PlaybackInfo scan and
    /// may read the source fine. If it cannot, the channel is genuinely
    /// dead server-side and no client request shape can revive it.
    static func liveSourceVideoCodecUnknown(_ source: PlaybackMediaSource) -> Bool {
        guard let video = source.mediaStreams?.first(where: { $0.type == .video })
        else { return true }
        return (video.codec ?? "").isEmpty
    }

    static func liveNeedsVideoReencode(transcodeReasons: [String]?, transcodingURL: String?) -> Bool {
        if (transcodeReasons ?? []).contains("VideoCodecNotSupported") { return true }
        guard let t = transcodingURL,
              let comps = URLComponents(string: t.hasPrefix("http") ? t : "http://x" + t),
              let reasons = comps.queryItems?.first(where: { $0.name == "TranscodeReasons" })?.value
        else { return false }
        return reasons.split(separator: ",").map(String.init).contains("VideoCodecNotSupported")
    }

}
