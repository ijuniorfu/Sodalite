import Foundation
import Combine
import Observation
import AetherEngine
import AVKit
import os

/// ViewModel that bridges AetherEngine with Jellyfin session reporting
/// and our custom tvOS-style player UI.
///
/// Uses Combine subscriptions to observe AetherEngine's @Published
/// properties instead of polling timers, eliminates AttributeGraph cycles.
///
/// Split into extensions:
/// - `PlayerViewModel+Scrubbing.swift`, pan/arrow scrubbing
/// - `PlayerViewModel+NextEpisode.swift`, auto-play next episode
/// - `PlayerViewModel+SessionReporting.swift`, Jellyfin progress reports
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - UI State

    var isLoading = true
    var errorMessage: String?
    /// Icon (SF Symbol) chosen for the active error, set together
    /// with `errorMessage` via `setError(from:)`. nil when no error.
    var errorIcon: String?
    /// Localised headline for the active error (e.g. "Connection
    /// problem" / "Sign-in required"). Sits above `errorMessage` in
    /// the player overlay; the message provides the detail.
    var errorTitle: String?
    var isPlaying = false
    var showControls = false

    // Time display
    var currentTime: String = "00:00"
    var totalTime: String = "00:00"
    var remainingTime: String = "-00:00"
    var progress: Float = 0

    // Playback time (raw seconds, tracked by @Observable for subtitle sync)
    var playbackTime: Double = 0

    /// Source-PTS time of the currently displayed frame, mirrored from
    /// `AetherEngine.sourceTime`. On the native HLS path AVPlayer's
    /// clock sits at `source_pts - producer.videoShiftPts`, so cues
    /// from the side-demuxer (raw source PTS) need this view of the
    /// timeline to render in sync. Equal to `playbackTime` on the SW
    /// path where the clock and source PTS already match.
    var subtitleTime: Double = 0

    // Scrubbing
    var isScrubbing = false
    var scrubProgress: Float = 0
    var scrubTime: String = "00:00"
    var displayedProgress: Float { isScrubbing ? scrubProgress : progress }
    var scrubStartProgress: Float = 0

    // Custom focus for transport bar navigation
    var controlsFocus: ControlsFocus = .progressBar
    var trackDropdown: TrackDropdown = .none

    enum ControlsFocus: Hashable {
        case progressBar
        case skipIntroButton
        case chapterButton
        case episodeButton
        case audioButton
        case subtitleButton
        case speedButton
        case pictureButton
        case infoButton
    }

    /// True while the stats-for-nerds side panel is mounted. Toggled
    /// by pressing the transport bar's info chip; the chip itself only
    /// appears when `preferences.showStatsForNerds` is on so casual
    /// users never see either. When set to `true` the side panel
    /// captures all remote presses (up/down scroll, menu/select
    /// dismiss) so the player UI behind it stays inert until the
    /// user closes the panel.
    var showStatsOverlay: Bool = false {
        didSet {
            // Reset the scroll cursor each time the overlay opens so
            // the user always starts at the Playback section regardless
            // of where they were last time. Closing doesn't need to
            // reset; the next open clears it.
            if showStatsOverlay && !oldValue {
                statsSectionIndex = 0
            }
        }
    }

    /// Section anchor cursor for the stats-for-nerds side panel. 0
    /// addresses the first section (Playback), N-1 the last (File).
    /// Up/down arrow presses while the panel is open shift this index;
    /// `StatsOverlayView` watches it via `scrollTo`. Range is clamped
    /// by `statsSectionAnchors.count`.
    var statsSectionIndex: Int = 0

    /// Ordered anchor IDs the stats panel attaches to each section.
    /// Up/down cursor jumps move between these, so the user pages
    /// through Playback → Video → Audio → Subtitles → File without
    /// needing per-row focus.
    static let statsSectionAnchors: [String] = [
        "stats.section.live",       // 0 — always shown when stats on
        "stats.section.playback",   // 1
        "stats.section.video",      // 2
        "stats.section.audio",      // 3
        "stats.section.subtitle",   // 4
        "stats.section.file",       // 5
        "stats.section.engine",     // 6 — gated by showEngineDiagnostics
        "stats.section.buffer",     // 7 — gated by showEngineDiagnostics
        "stats.section.network",    // 8 — gated by showEngineDiagnostics
    ]

    enum TrackDropdown: Equatable {
        case none
        case chapter(highlighted: Int)  // index into chapters
        case episode(highlighted: Int)  // index into seasonEpisodes
        case audio(highlighted: Int)   // index into displayAudioTracks
        case subtitle(highlighted: Int) // index into subtitle items (0=Off, 1..=displaySubtitleStreams)
        case speed(highlighted: Int)    // index into PlayerViewModel.speedOptions
        case picture(highlighted: Int)  // index into PlaybackPreferences.PictureMode.allCases
    }

    var isDropdownOpen: Bool { trackDropdown != .none }

    /// Playback speed choices. Native tvOS player uses the same stepped
    /// set, keeping it consistent with user expectations. Index 2 = 1.0×.
    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    /// Index into `speedOptions` for the currently applied rate.
    var activeSpeedIndex: Int = 2

    // Tracks
    var subtitleCues: [SubtitleCue] = []
    var activeAudioIndex: Int?
    var activeSubtitleIndex: Int?

    /// Audio tracks in picker order: container-default first, then demuxer order. All picker UI indexes here, not into `player.audioTracks`.
    var displayAudioTracks: [TrackInfo] {
        let tracks = player.audioTracks
        return tracks.filter { $0.isDefault } + tracks.filter { !$0.isDefault }
    }

    /// Subtitle streams in picker order: Jellyfin-default first, then source order. All picker UI indexes here (with the "Off" row at position 0), not into `subtitleStreams`.
    var displaySubtitleStreams: [MediaStream] {
        let streams = subtitleStreams
        return streams.filter { $0.isDefault == true } + streams.filter { $0.isDefault != true }
    }

    /// Episodes from the currently-playing item's season, sorted by
    /// indexNumber. Populated lazily after startPlayback so the
    /// transport bar can offer an in-season episode picker without
    /// the user having to back out to the series detail screen.
    /// Stays empty for movies, single-episode series, and any item
    /// without a parent season, TransportBar suppresses the button
    /// when count <= 1.
    var seasonEpisodes: [JellyfinItem] = []

    /// Chapter markers from the source container. Populated at
    /// startPlayback from `item.chapters`. Sorted by start position
    /// so the scrub-bar overlay can iterate without re-sorting and
    /// the chapter dropdown lists them in playback order. Empty when
    /// the file ships no chapters, TransportBar suppresses the
    /// button when count <= 1.
    var chapters: [ChapterInfo] = []

    /// Picture-fill mode for the currently active session. Initialised
    /// at `startPlayback` from the user's `PlaybackPreferences.pictureMode`,
    /// then mutable on the fly via `selectPictureMode`. Doesn't write
    /// back to prefs, the in-player picker is treated as a transient
    /// override for this playback only, the settings screen owns the
    /// global default.
    var pictureMode: PlaybackPreferences.PictureMode = .original

    // Video format (HDR/DV indicator)
    var videoFormat: VideoFormat = .sdr

    // Next episode
    var nextEpisode: JellyfinItem?
    var showNextEpisodeOverlay = false
    var nextEpisodeCountdown = 10
    /// Fired once when playback hits demux EOF and there's no next
    /// episode to advance to (movies, last episode of a season /
    /// series). PlayerHostController wires this up to the same dismiss path the
    /// Menu button takes, without it, the player sits on a black
    /// frame with no focus target and the user has to mash Menu to
    /// get back to the detail screen they came from.
    var onPlaybackReachedEnd: (() -> Void)?

    /// Fires whenever `isInsideIntro` flips. The host hooks this to
    /// add / remove the "Skip Intro" entry in
    /// `AVPlayerViewController.contextualActions`, the documented
    /// tvOS surface for time-bound playback actions.
    var onIntroStateChanged: ((Bool) -> Void)?

    var isCountdownActive = false
    var nextEpisodeTimer: Task<Void, Never>?
    var hasFetchedNextEpisode = false
    var nextEpisodeCancelled = false

    /// Last `currentTime` observed by the next-episode visibility
    /// hook. Used to detect backward time movement (user scrubs back
    /// from the trigger window) so the overlay + countdown can reset.
    /// Without this the show-logic is one-way ("if remaining < 30
    /// and overlay hidden, show it") and the overlay sticks on screen
    /// when the user scrubs out of the end window.
    var lastPlaybackTimeForNextEpisode: Double = 0

    // Intro skip + outro-aware next-episode trigger, both populated
    // from Jellyfin Media Segments / intro-skipper plugin in one call.
    var introSegment: MediaSegment?
    var outroSegment: MediaSegment?
    /// True while playbackTime is inside the intro range. UI shows the
    /// Skip Intro button whenever this is true, regardless of whether
    /// the transport controls are open.
    var isInsideIntro: Bool = false
    /// Set once per episode after an auto-skip fires, keeps the time
    /// subscriber from re-triggering the skip in the brief window before
    /// the seek actually moves currentTime past introEnd.
    var didAutoSkipCurrentIntro: Bool = false
    /// Mirrors `didAutoSkipCurrentIntro` for the outro segment. Set the
    /// first tick after playback crosses into the outro range; prevents
    /// the auto-skip from firing repeatedly while currentTime ticks
    /// through the couple of seconds between the marker and the seek
    /// landing on outro.endSeconds.
    var didAutoSkipCurrentOutro: Bool = false
    /// Latches once the user (or auto-skip) has skipped this episode's
    /// intro. While set, `updateIntroVisibility` refuses to flip
    /// `isInsideIntro` back to true regardless of the currentTime
    /// value reported, so stale pre-seek ticks arriving between
    /// `skipIntro`'s synchronous flag flip and the actual seek landing
    /// cannot revive the Skip Intro pill mid-fade-out. Cleared 500 ms
    /// after `player.seek` returns (absorbing AVPlayer's post-seek
    /// time jitter) so a subsequent deliberate backward scrub into or
    /// past the intro range re-offers the pill. Also cleared on
    /// episode change and as a fast path when a tick arrives with
    /// `time < seg.startSeconds` before the settle window expires.
    var didSkipCurrentIntro: Bool = false

    // MARK: - Dependencies

    var item: JellyfinItem
    let player: AetherEngine

    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    var startFromBeginning: Bool
    var cachedPlaybackInfo: PlaybackInfoResponse?
    let preferences: PlaybackPreferences

    /// Produces the scrub-preview thumbnail via the session FrameExtractor.
    /// Configured per session in `startPlayback`, reset in `stopPlayback`.
    let scrubPreview: ScrubPreviewProvider

    /// Session-scoped frame extractor. Built from the static stream URL
    /// once per `startPlayback` and shut down in `stopPlayback`. Shared
    /// by `scrubPreview` and `chapterThumbnail(forIndex:)`.
    @ObservationIgnored private var frameExtractor: FrameExtractor?

    /// A still for a chapter, decoded from the session extractor at the
    /// chapter's start time. Nil if no extractor or index out of range.
    func chapterThumbnail(forIndex index: Int) async -> CGImage? {
        guard let frameExtractor, chapters.indices.contains(index) else { return nil }
        return await frameExtractor.thumbnail(at: chapters[index].startSeconds, maxWidth: 320)
    }

    // MARK: - Internal State

    var cancellables = Set<AnyCancellable>()
    var progressTimer: Task<Void, Never>?
    var progressReportOnDemandTask: Task<Void, Never>?
    var controlsTimer: Task<Void, Never>?
    /// The in-flight continuous (hold-to-seek) scrub task. Non-nil while a
    /// left/right press is held; advances scrubProgress with acceleration
    /// until the press is released (see PlayerViewModel+Scrubbing).
    var continuousSeekTask: Task<Void, Never>?
    /// The in-flight initial-launch task (see `beginPlayback`). Held so
    /// a back-press during the loading spinner can cancel it before it
    /// calls `player.load()` on the shared engine. Without this, the
    /// untracked task would resume after `stopPlayback()`'s
    /// `player.stop()` and restart playback behind the dismissed player,
    /// leaving audio running until an app restart.
    var loadTask: Task<Void, Never>?
    /// Latched true by `stopPlayback()`. `startPlayback()` resets it at
    /// entry and re-checks it after every `await` so a teardown that
    /// races an in-flight load (including the next-episode / season-picker
    /// transitions, whose tasks aren't `loadTask` and so can't be
    /// cancelled) still bails before, or immediately stops after,
    /// `player.load()`.
    var isTearingDown = false
    var hasReportedStart = false
    var hasStartedPlaying = false
    /// The position we resumed from, used as minimum for progress reports
    /// to prevent Jellyfin from resetting progress when stopping early.
    var resumePositionTicks: Int64 = 0
    var mediaSourceID: String = ""
    var playSessionID: String?
    var activePlayMethod: PlayMethod = .directPlay
    var subtitleStreams: [MediaStream] = []

    // MARK: - Live TV

    /// True when this session is a live channel rather than VOD. Gates DVR
    /// transport and disables resume / chapters / next-episode.
    private(set) var isLiveSession = false
    /// The Jellyfin tuner handle for the current live stream; captured on
    /// load, released on teardown. Nil for VOD.
    var activeLiveStreamID: String?
    /// Live-edge mirror fields, populated by PlayerViewModel+Live from the
    /// engine's published live surfaces.
    var liveSeekableRange: ClosedRange<Double>?
    var isAtLiveEdge: Bool = true
    var behindLiveSeconds: Double = 0
    /// The channel being played, for live sessions. Nil for VOD.
    let liveChannel: JellyfinChannel?
    /// The live-TV service used by PlayerViewModel+Live for tuner lifecycle.
    /// Nil for VOD.
    let liveTvService: JellyfinLiveTvServiceProtocol?

    init(
        item: JellyfinItem,
        startFromBeginning: Bool,
        playbackService: JellyfinPlaybackServiceProtocol,
        userID: String,
        preferences: PlaybackPreferences,
        cachedPlaybackInfo: PlaybackInfoResponse? = nil,
        isLiveSession: Bool = false,
        liveChannel: JellyfinChannel? = nil,
        liveTvService: JellyfinLiveTvServiceProtocol? = nil
    ) {
        self.item = item
        self.player = DependencyContainer.playerEngine
        self.startFromBeginning = startFromBeginning
        self.playbackService = playbackService
        self.userID = userID
        self.preferences = preferences
        self.scrubPreview = ScrubPreviewProvider()
        self.cachedPlaybackInfo = cachedPlaybackInfo
        self.isLiveSession = isLiveSession
        self.liveChannel = liveChannel
        self.liveTvService = liveTvService
    }

    // MARK: - Lifecycle

    /// Initial-launch entry point called by the host VC as the modal
    /// appears. Routes through a tracked task so a back-press during the
    /// loading spinner can cancel the in-flight `startPlayback()` (the
    /// engine throws `CancellationError` out of `player.load()` on
    /// cancel) before it touches the shared engine. The bare
    /// `Task { await startPlayback() }` it replaces was untracked, so a
    /// dismiss mid-load left the task to resume after `player.stop()` and
    /// restart playback behind a gone player.
    func beginPlayback() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.startPlayback() }
    }

    func startPlayback() async {
        isTearingDown = false
        isLoading = true
        clearError()
        // Source-container chapters are already on the item if the
        // detail fetch requested the Chapters field. Sort defensively
        //, the API documents start-position order but a few legacy
        // taggers emit them out of sequence.
        chapters = (item.chapters ?? [])
            .sorted { $0.startPositionTicks < $1.startPositionTicks }
        // Reset the picture mode to the user's global default for
        // each new playback session, in-player overrides shouldn't
        // bleed across episodes / movies.
        pictureMode = preferences.pictureMode
        applyPictureMode()
        #if DEBUG
        print("[PlayerVM] startPlayback: item=\(item.name), seriesId=\(item.seriesId ?? "nil"), type=\(item.type), chapters=\(chapters.count)")
        #endif

        // Now Playing is driven by AVKit's internal session: it
        // activates automatically when `showsPlaybackControls = true`
        // (set on the host VC) and an AVPlayer is assigned, and
        // reads title/description/artwork off
        // `AVPlayerItem.externalMetadata`. The engine stages those
        // via setExternalMetadata pre-load; we refresh with cover
        // post-load below. The 10s skip remote commands are opt-in
        // so we bind them explicitly on the shared command center.
        bindRemoteSkipCommands()

        do {
            // Live channels take a dedicated load path: open the tuner,
            // pick the infinite live MediaSource, and hand it to the engine
            // with isLive + a DVR window. The VOD wiring below (resume,
            // chapters, intro markers, episode picker) does not apply, so we
            // reproduce only the shared post-load steps and return. Kept as a
            // separate branch on purpose: the VOD path below stays untouched.
            if isLiveSession {
                stageInitialNowPlayingMetadata()
                try await loadLiveStream()
                if Task.isCancelled || isTearingDown {
                    player.stop()
                    isLoading = false
                    return
                }
                // Shared post-load wiring (mirrors the VOD path; live skips
                // resume, chapters, intro markers, and the episode picker).
                // Duplicated rather than extracted to keep the VOD path intact.
                let preferredAudio = effectivePreferredAudioLanguage()
                let chosenAudio = player.audioTracks.first(where: {
                    preferredAudio != nil && Self.languagesMatch($0.language, preferredAudio)
                }) ?? player.audioTracks.first(where: { $0.isDefault })
                  ?? player.audioTracks.first
                if let chosenAudio, chosenAudio.id != player.activeAudioTrackIndex {
                    player.selectAudioTrack(index: chosenAudio.id)
                }
                applyPreferredSubtitle(forAudioLanguage: chosenAudio?.language)
                isLoading = false
                isPlaying = true
                startObserving()
                Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
                await reportStart()
                startProgressReporting()
                return
            }

            let info: PlaybackInfoResponse
            if let cached = cachedPlaybackInfo, !cached.mediaSources.isEmpty {
                info = cached
            } else {
                info = try await playbackService.getPlaybackInfo(
                    itemID: item.id,
                    userID: userID,
                    profile: DirectPlayProfile.current()
                )
            }
            playSessionID = info.playSessionId

            guard let source = info.mediaSources.first else {
                throw PlayerEngineError.noSource
            }
            mediaSourceID = source.id

            #if DEBUG
            print("[PlayerViewModel] Source: container=\(source.container ?? "nil"), directPlay=\(source.supportsDirectPlay ?? false), directStream=\(source.supportsDirectStream ?? false), transcoding=\(source.supportsTranscoding ?? false)")
            if let tURL = source.transcodingUrl {
                print("[PlayerViewModel] TranscodingURL: \(tURL.prefix(120))...")
            }
            #endif

            // Filter subtitle streams:
            // 1. Exclude image-based formats (PGS, VOBSUB), can't convert to text
            // 2. Drop forced tracks, they only cover foreign-dialogue
            //    segments inside an otherwise-understood audio track, so
            //    users rarely want them on; keeping them also poisons the
            //    preferred-language auto-select (a forced "deu" beats a
            //    full "deu" track if it comes first).
            // 3. Deduplicate same-language streams with no distinguishing metadata.
            // Bitmap codecs (PGS / HDMV / DVB / DVD) used to be excluded
            // here because the legacy server-extraction path couldn't
            // produce SRT for them. The engine renders them as CGImage
            // now, so they belong in the picker. "Forced" tracks also
            // stay in the list, many releases mark every subtitle
            // track as forced and we'd otherwise leave the user with
            // an empty dropdown for a file that obviously has subs.
            // The dedupe step below uses `forced` / `signs` / `sdh` /
            // etc. as descriptors so distinct tracks for the same
            // language don't collapse into one.
            let allSubStreams = source.mediaStreams?.filter { stream in
                stream.type == .subtitle
            } ?? []

            // Deduplicate: if multiple streams share the same language and
            // neither has a distinguishing title (SDH, Forced, etc.),
            // keep only the first one. Streams with descriptors keep
            // each variant under its own key so e.g. "Forced (SRT)"
            // and "Full (PGS)" both survive even when they share a
            // language tag.
            var seen = Set<String>()
            subtitleStreams = allSubStreams.filter { stream in
                let lang = stream.language ?? "und"
                let hasDescriptor = stream.isForced == true
                    || (stream.title?.lowercased()).map { t in
                        ["sdh", "commentary", "cc", "signs", "songs", "hearing", "forced", "musik", "music", "full"].contains(where: { t.contains($0) })
                    } ?? false
                let codecKey = stream.codec?.lowercased() ?? ""
                let key = hasDescriptor
                    ? "\(lang)_\(stream.title ?? "")_\(codecKey)"
                    : "\(lang)_\(codecKey)"
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }

            let url: URL
            if source.supportsDirectPlay == true || source.supportsDirectStream == true {
                let isDirectPlay = source.supportsDirectPlay == true
                guard let directURL = playbackService.buildStreamURL(
                    itemID: item.id,
                    mediaSourceID: source.id,
                    container: source.container,
                    isStatic: isDirectPlay
                ) else {
                    throw PlayerEngineError.noURL
                }
                url = directURL
                activePlayMethod = isDirectPlay ? .directPlay : .directStream
                #if DEBUG
                print("[PlayerViewModel] Using direct \(isDirectPlay ? "play" : "stream")")
                #endif
            } else if let transcodePath = source.transcodingUrl, !transcodePath.isEmpty {
                guard let transcodeURL = playbackService.buildTranscodeURL(relativePath: transcodePath) else {
                    throw PlayerEngineError.noURL
                }
                url = transcodeURL
                activePlayMethod = .transcode
                #if DEBUG
                print("[PlayerViewModel] Using transcoded stream")
                #endif
            } else {
                throw PlayerEngineError.noURL
            }

            // Scrub preview + chapter thumbnails decode stills from the
            // original file via FFmpeg, independent of how playback
            // streams it (direct or transcode). Build against
            // buildStreamURL(isStatic:true) so transcode sessions still
            // get a preview. api_key rides in the URL query.
            if let previewURL = playbackService.buildStreamURL(
                itemID: item.id, mediaSourceID: source.id,
                container: source.container, isStatic: true
            ) {
                frameExtractor = FrameExtractor(url: previewURL, httpHeaders: [:])
            } else {
                frameExtractor = nil
            }
            scrubPreview.configure(
                extractor: frameExtractor,
                enabled: preferences.showScrubPreview
            )

            let startPos: Double?
            if !startFromBeginning,
               let ticks = item.userData?.playbackPositionTicks, ticks > 0 {
                startPos = ticks.ticksToSeconds
                resumePositionTicks = ticks
            } else {
                startPos = nil
                resumePositionTicks = 0
            }

            // Stage title / description as externalMetadata BEFORE
            // engine.load so the engine applies it to the AVPlayerItem
            // pre-replaceCurrentItem. Cover follows asynchronously
            // post-load via refreshExternalMetadataWithArtwork(),
            // which the engine writes onto the live AVPlayerItem;
            // AVKit's internal Now Playing session re-reads
            // externalMetadata automatically.
            //
            stageInitialNowPlayingMetadata()

            // Bail before touching the shared engine if the player was
            // torn down while we awaited playback info (user pressed Back
            // during the loading spinner). Otherwise this in-flight task
            // calls player.load() AFTER stopPlayback()'s player.stop(),
            // restarting playback with no UI to dismiss it, audio keeps
            // running until an app restart.
            if Task.isCancelled || isTearingDown {
                isLoading = false
                return
            }

            // Single load path: hand the source to the engine and let
            // it pick AVPlayer-backed native (the default) or fall
            // through to its legacy aether sample-buffer path for
            // codecs HLSVideoEngine still rejects (VP9 / AV1 until
            // Phase 3; DV P7 always). Format detection, HDMI HDR
            // handshake, AVPlayerLayer ownership, and refresh-rate
            // matching all live inside engine.load(url:options:) now.
            LogTap.shared.note("[PlayerVM] engine.load url=\(url.absoluteString)")
            // Two panel-state inputs feed the engine's master-vs-media
            // playlist routing:
            // - `matchContentEnabled` mirrors the tvOS Match Content
            //   master toggle (Dynamic Range OR Frame Rate). False means
            //   tvOS keeps the panel locked in its current mode, so the
            //   engine knows AVPlayer can't drive a panel-mode switch.
            // - `panelIsInHDRMode` reflects whether the panel is right
            //   now in HDR (EDR active). True means master-playlist
            //   routing is safe regardless of the match flag, because
            //   the panel already accepts HDR signaling and any
            //   SUPPLEMENTAL-CODECS=dvh1 upgrade hint can land per
            //   DrHurt's empirical test in AetherEngine#4. False (panel
            //   currently SDR) means the engine falls back to media for
            //   HDR sources unless match-content is on AND the display
            //   can do HDR, since otherwise AVPlayer fails asset open
            //   with `Cannot Open` (-11848) on a master that claims
            //   HDR while the panel sits in SDR.
            // Engine drives the criteria pre-flight; AVKit's auto
            // path is disabled on PlayerHostController so only one
            // writer touches AVDisplayManager.preferredDisplayCriteria
            // per session. The engine's apply() fires BEFORE asset.load
            // and blocks on the two-stage waitForSwitch (AetherEngine
            // c08dcfc) until the panel actually reaches the target
            // dynamic range, which is the only way to guarantee the
            // panel is in DV mode before AVPlayer attempts to decode
            // the first DV5 frame. The earlier waitForSwitch
            // implementation had an async-handshake race that broke
            // DV8.1 on HDR10 panels (commit 7f225e74 → fd3368c8
            // revert); c08dcfc's two-stage poll closes that gap.
            // AVKit is the sole criteria writer (host has
            // appliesPreferredDisplayCriteriaAutomatically=true on
            // PlayerHostController), engine pre-flight is OFF via
            // suppressDisplayCriteria=true. AVKit reads the live
            // AVPlayerItem.formatDescription (which has dvcC parsed
            // from the fMP4 sample entry via private CoreMedia hooks)
            // and writes correct DV criteria the panel actually
            // honours. The engine's job shrinks to GATING play() on
            // the panel handshake completion (AetherEngine 5d60dbb).
            // See PlayerHostController's init comment for the full
            // architecture rationale.
            try await player.load(
                url: url,
                startPosition: startPos,
                options: LoadOptions(
                    suppressDisplayCriteria: false,
                    matchContentEnabled: Self.matchDynamicRangeEnabled,
                    panelIsInHDRMode: Self.panelIsInHDRMode,
                    audioBridgeMode: preferences.audioBridgeMode
                )
            )

            // Teardown can land in the tiny window between load() returning
            // and us wiring up observation (back-press just as the engine
            // finished opening the asset). Stop the engine we just started
            // and bail so nothing plays behind the dismissed player.
            if Task.isCancelled || isTearingDown {
                player.stop()
                isLoading = false
                return
            }

            totalTime = formatSeconds(effectiveDuration)
            // Audio track priority: preferred language → stream default → first.
            // Engine has already picked the container's default; we only
            // call selectAudioTrack if the user's preferred language is
            // available and differs from that pick, which goes through
            // the reload path (one extra ~1 s pipeline restart at session
            // start). Common case: preferred language matches default,
            // no reload happens.
            let preferredAudio = effectivePreferredAudioLanguage()
            let chosenAudio = player.audioTracks.first(where: {
                preferredAudio != nil && Self.languagesMatch($0.language, preferredAudio)
            }) ?? player.audioTracks.first(where: { $0.isDefault })
              ?? player.audioTracks.first
            if let chosenAudio, chosenAudio.id != player.activeAudioTrackIndex {
                player.selectAudioTrack(index: chosenAudio.id)
            }

            applyPreferredSubtitle(forAudioLanguage: chosenAudio?.language)

            isLoading = false
            isPlaying = true

            startObserving()
            // Cover fetch happens async post-load; the engine writes
            // the updated externalMetadata to the live AVPlayerItem
            // and the session republishes automatically when the
            // task completes.
            Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
            await reportStart()
            startProgressReporting()

            // Fetch intro marker in the background, don't block
            // playback start if the server is slow or doesn't expose
            // the endpoint. Once the marker lands the next time tick
            // will flip isInsideIntro on naturally.
            Task { [weak self] in await self?.loadEpisodeSegments() }

            // Same fire-and-forget: the season episode list powers the
            // transport-bar episode picker. A movie or single-episode
            // series leaves the list empty and the picker stays hidden.
            Task { [weak self] in await self?.loadSeasonEpisodes() }

        } catch {
            setError(from: error)
            isLoading = false
        }
    }

    /// Apple TV's "Match Dynamic Range" toggle. Read at the same
    /// instant the host renders an HDR badge so the badge only shows
    /// when the panel is actually engaging HDR mode for the current
    /// session.
    static var matchDynamicRangeEnabled: Bool {
        #if os(tvOS)
        guard let win = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first
        else { return false }
        return win.avDisplayManager.isDisplayCriteriaMatchingEnabled
        #else
        return false
        #endif
    }

    /// Snapshot of whether the connected panel is currently presenting
    /// in HDR (EDR active). Read off `UIScreen.currentEDRHeadroom`,
    /// which AVKit / UIKit publishes per active display; > 1.0 means
    /// the panel is in an HDR mode and accepting extended-range pixels
    /// at this moment. Feeds the engine's master-vs-media playlist
    /// routing as the strong signal that master-playlist routing is
    /// safe even with Match Dynamic Range off (per DrHurt's
    /// HDR10-locked-panel-upgrades-to-DV test in AetherEngine#4).
    static var panelIsInHDRMode: Bool {
        #if os(tvOS)
        guard let win = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first
        else { return false }
        // `currentEDRHeadroom == 1.0` means the panel is in SDR; > 1.0
        // means HDR is active and the renderer can present brighter-
        // than-paper-white pixels. Use a small epsilon to dodge a
        // floating-point comparison glitch on the boundary.
        return win.screen.currentEDRHeadroom > 1.001
        #else
        return false
        #endif
    }

    /// Tear down the active playback session. Synchronous local
    /// work (progress reporting, KVO, engine stop) finishes inline;
    /// the network "reportStop" round-trip is detached into a
    /// background Task so a slow / hiccupping Jellyfin server can't
    /// stall the dismiss path. The default 30 s URLRequest timeout on
    /// the report would otherwise leave the user staring at a still-up
    /// player after their back press on a slow CDN (DrHurt #12). Same
    /// fire-and-forget shape `playNextEpisode` already uses. The
    /// session endpoints also opt into a 90 s timeout so the position
    /// write survives a slow origin without being silently dropped.
    func stopPlayback() {
        // Latch teardown and cancel the in-flight launch first. The flag
        // is re-checked after every await in startPlayback; the cancel
        // makes the engine throw CancellationError out of an in-flight
        // player.load(). Together they stop a back-press-during-load from
        // resuming into player.load() after the player.stop() below.
        isTearingDown = true
        loadTask?.cancel()
        loadTask = nil
        stopProgressReporting()
        progressReportOnDemandTask?.cancel()
        progressReportOnDemandTask = nil
        unbindRemoteSkipCommands()
        scrubPreview.reset()
        let extractorToClose = frameExtractor
        frameExtractor = nil
        Task { await extractorToClose?.shutdown() }
        // AVKit clears its internal Now Playing registration when
        // the host VC sets `player = nil` (done in dismissPlayer /
        // viewWillDisappear).
        cancellables.removeAll()
        // Capture position synchronously, then stop the engine, then
        // fire-and-forget the report. The capture-then-stop order is
        // critical: player.stop() resets currentTime to 0, so we'd
        // lose the position if we read it inside reportStop after
        // the stop.
        let finalTicks = currentPositionTicks
        // Snapshot the report payload + service BEFORE engine teardown
        // and detach with a strong capture. If we used `[weak self]`,
        // PlayerHostController's dismissal could deallocate the view model before
        // the @MainActor hop ran, dropping the position write silently
        // (precisely DrHurt's "don't timeout on it too soon" concern,
        // just via lifecycle instead of network). The detached task
        // owns everything it needs to complete on its own.
        let svc = playbackService
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: finalTicks,
            liveStreamId: nil
        )
        // Engine handles native AVPlayer teardown + HLS server shutdown
        // + AVDisplayManager criteria reset inside stopInternal(). The
        // host just calls stop() and trusts the engine to leave the
        // session in a clean state for the next playback.
        player.stop()
        // Fire-and-forget: caller (dismissPlayer / viewWillDisappear)
        // returns immediately so the SwiftUI dismiss animation can
        // start without waiting on Jellyfin's PlaybackStopped endpoint.
        Task.detached {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                await MainActor.run {
                    NotificationCenter.default.post(name: .playbackProgressDidChange, object: nil)
                }
            } catch {
                #if DEBUG
                print("[SessionReport] Stop FAILED: \(error)")
                #endif
            }
        }
    }

    // MARK: - State Observation (Combine)

    private func startObserving() {
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    self.hasStartedPlaying = true
                    self.isLoading = false
                    self.isPlaying = true
                    if self.showControls { self.scheduleControlsHide() }
                case .paused:
                    self.isLoading = false
                    self.isPlaying = false
                case .idle:
                    self.isPlaying = false
                    // Demux EOF, safety net countdown start for cases
                    // where player.$currentTime never fires near the
                    // end (Combine only emits on value changes, and
                    // the demux's 15–20 s look-ahead means currentTime
                    // can stall a few seconds short of duration). Cap
                    // at 10 s so the overlay copy stays readable even
                    // if the real remaining is tiny.
                    if self.hasStartedPlaying,
                       self.nextEpisode != nil,
                       !self.nextEpisodeCancelled,
                       self.nextEpisodeTimer == nil {
                        let remaining = self.effectiveDuration - self.playbackTime
                        let seconds = min(10, max(1, Int(ceil(max(0, remaining)))))
                        self.showNextEpisodeOverlay = true
                        self.startNextEpisodeCountdown(from: seconds)
                    } else if self.hasStartedPlaying,
                              self.nextEpisode == nil,
                              !self.showNextEpisodeOverlay {
                        // Real end-of-content: a movie just finished, or
                        // the last episode of a series rolled credits.
                        // The engine reaches .idle on stop(); for native
                        // sessions, end-of-stream auto-dismiss currently
                        // depends on the user / next-episode countdown
                        // since AVPlayer's didPlayToEnd → engine state
                        // wiring is a follow-up.
                        self.onPlaybackReachedEnd?()
                    }
                case .loading:
                    if !self.hasStartedPlaying { self.isLoading = true }
                case .seeking:
                    break
                case .error(let msg):
                    self.setEnginePlaybackError(message: msg)
                    self.isLoading = false
                }
            }
            .store(in: &cancellables)

        player.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.subtitleTime = t }
            .store(in: &cancellables)

        player.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.playbackTime = time
                // Segment markers (intro/outro) from Jellyfin live on the
                // absolute source timeline; player.currentTime is the
                // AVPlayer clock (source - playlistShiftSeconds on the
                // native HLS path). Compare against sourceTime so the
                // ranges line up regardless of the per-session shift,
                // mirroring how the subtitle path already keys off it.
                self.updateIntroVisibility(time: self.player.sourceTime)
                self.updateOutroAutoSkip(time: self.player.sourceTime)
                self.checkForNextEpisode()
                let dur = self.effectiveDuration
                let remaining = dur - time

                // Detect backward time movement (scrub-back) and reset
                // the next-episode overlay + countdown so the user
                // sees the same fresh trigger when they return to the
                // end. Tolerate small jitter from AVPlayer's internal
                // precision; only > 1 s backward counts as a real
                // scrub. The forward-trigger logic below re-fires
                // naturally on the next tick once the user reaches
                // the trigger window again.
                let movedBackward = time + 1.0 < self.lastPlaybackTimeForNextEpisode
                self.lastPlaybackTimeForNextEpisode = time
                if movedBackward, self.showNextEpisodeOverlay {
                    self.resetNextEpisodeOverlayState()
                }

                if self.nextEpisode != nil && !self.nextEpisodeCancelled && dur > 0 && remaining > 0 {
                    // Two separate UI-visibility flows depending on
                    // whether the server gave us an outro marker.
                    //
                    // Outro available:
                    //   Credits typically run 2–3 minutes. Show the
                    //   overlay the moment we cross outro.startSeconds
                    //   and fire a fixed 10 s countdown, transition
                    //   happens well before the episode naturally ends,
                    //   cutting through the credits.
                    //
                    // No outro:
                    //   Fall back to "show at 30 s, countdown at 10 s
                    //   remaining, synced to the clock." Countdown
                    //   hits 0 right at playback end, seamless
                    //   transition that doesn't cut anything off.
                    if let outro = self.outroSegment {
                        // sourceTime, not the AVPlayer clock: outro.startSeconds
                        // is an absolute source-timeline marker.
                        let pastOutroStart = self.player.sourceTime >= outro.startSeconds
                        if pastOutroStart && !self.showNextEpisodeOverlay {
                            self.showNextEpisodeOverlay = true
                        }
                        if pastOutroStart, self.nextEpisodeTimer == nil, self.showNextEpisodeOverlay {
                            self.startNextEpisodeCountdown()
                        }
                    } else {
                        if !self.showNextEpisodeOverlay && remaining < 30 {
                            self.showNextEpisodeOverlay = true
                        }
                        if remaining <= 10, self.nextEpisodeTimer == nil, self.showNextEpisodeOverlay {
                            self.startNextEpisodeCountdown(from: Int(ceil(remaining)))
                        }
                    }
                }
                guard !self.isScrubbing else { return }
                self.currentTime = self.formatSeconds(time)
                let rem = dur - time
                self.remainingTime = rem > 0 ? "-\(self.formatSeconds(rem))" : "-00:00"
                self.progress = dur > 0 ? Float(time / dur) : 0
                // Keep one frame warm at the playhead so the first scrub frame
                // is already on screen the instant the user swipes to scrub.
                self.scrubPreview.warm(toSeconds: time)
            }
            .store(in: &cancellables)

        player.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                guard let self else { return }
                self.totalTime = dur > 0 ? self.formatSeconds(dur) : "00:00"
            }
            .store(in: &cancellables)

        player.$videoFormat
            .receive(on: DispatchQueue.main)
            .sink { [weak self] format in
                guard let self else { return }
                // Engine sources videoFormat from its demuxer probe
                // and from late-discovered HDR10+ T.35 SEI mid-stream,
                // works for both backends. Log transitions for
                // TestFlight diagnostics.
                if format != self.videoFormat {
                    let line = "[PlayerVM] videoFormat changed: \(self.videoFormat) → \(format)"
                    print(line)
                    LogTap.shared.note(line)
                }
                // Only show the HDR badge if the panel actually went
                // to HDR mode. With Match Dynamic Range off, the TV
                // stays in SDR even for an HDR source, so showing
                // "HDR10" would be misleading.
                #if os(tvOS)
                if format != .sdr, !Self.matchDynamicRangeEnabled {
                    self.videoFormat = .sdr
                    return
                }
                #endif
                self.videoFormat = format
            }
            .store(in: &cancellables)

        // Engine subtitle pipeline, covers both embedded streams
        // (cues stream in from the main demux loop) and sidecar
        // files (cues arrive in one batch when SubtitleDecoder
        // finishes). Mirror them into our `subtitleCues` whenever
        // the engine is the source. The legacy HTTP path for
        // bitmap codecs / transcoded sessions writes `subtitleCues`
        // directly with `isSubtitleActive == false`, so the guard
        // keeps those two paths from clobbering each other.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                guard self.player.isSubtitleActive else { return }
                self.subtitleCues = cues
            }
            .store(in: &cancellables)

        // Engine is the source of truth for which audio track is
        // currently muxed: the picker reflects whatever the pipeline
        // actually settled on, including the brief window during a
        // mid-playback audio switch when the new HLSVideoEngine session
        // is still spinning up. Without this mirror, the picker would
        // claim the new track was active before AVPlayer had the new
        // item loaded, which made early scrubs look broken.
        player.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                self?.activeAudioIndex = index
            }
            .store(in: &cancellables)
    }

    // MARK: - Controls

    func togglePlayPause() {
        player.togglePlayPause()
        reportProgressIfNeeded()
        showControls = true
        scheduleControlsHide()
    }

    /// Seek by the user's configured interval (5/10/15/30 s). The
    /// direction is +1 (right) or −1 (left). Wraps the seconds variant
    /// so the press handler doesn't need a Preferences lookup.
    func seekJumpByConfiguredInterval(direction: Int) {
        let interval = preferences.skipIntervalSeconds
        let signed = (direction < 0 ? -1 : 1) * interval
        seekJump(seconds: Double(signed))
    }

    func seekJump(seconds: Double) {
        let dur = effectiveDuration
        guard dur > 0 else { return }

        if !isScrubbing {
            isScrubbing = true
            scrubStartProgress = progress
            scrubProgress = progress
        }

        showControls = true
        controlsTimer?.cancel()

        let jumpProgress = Float(seconds / dur)
        scrubProgress = max(0, min(1, scrubProgress + jumpProgress))
        scrubTime = formatSeconds(Double(scrubProgress) * dur)
        scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)

        // Auto-cancel on idle, matching `scrubPanEnded`. Commit stays
        // explicit (Select), but if the user taps left / right and
        // walks away without pressing anything else the scrub is
        // discarded after 5 s and the controls fade out, instead of
        // sitting on the picture forever.
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isScrubbing = false
            scrubPreview.clear()
            hideControls()
        }
    }

    /// Reset the error trio so a fresh `startPlayback` shows nothing
    /// stale while it loads.
    func clearError() {
        errorMessage = nil
        errorIcon = nil
        errorTitle = nil
    }

    /// Categorise an error from the playback-start path into an
    /// icon + title + body trio for the player overlay. The body
    /// stays the underlying `localizedDescription` (already localised
    /// for `APIError`) so the user sees the real reason; the icon
    /// and title give it shape.
    func setError(from error: Error) {
        let icon: String
        let title: String
        if let api = error as? APIError {
            switch api {
            case .serverUnreachable:
                icon = "wifi.exclamationmark"
                title = String(localized: "player.error.connection.title", defaultValue: "Connection problem")
            case .networkError:
                icon = "wifi.exclamationmark"
                title = String(localized: "player.error.connection.title", defaultValue: "Connection problem")
            case .timeout:
                icon = "clock.badge.exclamationmark"
                title = String(localized: "player.error.timeout.title", defaultValue: "Request timed out")
            case .unauthorized:
                icon = "lock.shield"
                title = String(localized: "player.error.unauthorized.title", defaultValue: "Sign-in required")
            case .httpError(let statusCode, _):
                if statusCode == 404 {
                    icon = "questionmark.folder"
                    title = String(localized: "player.error.notFound.title", defaultValue: "Item unavailable")
                } else if (500..<600).contains(statusCode) {
                    icon = "server.rack"
                    title = String(localized: "player.error.server.title", defaultValue: "Server error")
                } else {
                    icon = "exclamationmark.triangle"
                    title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
                }
            case .invalidURL, .invalidResponse, .decodingError:
                icon = "exclamationmark.triangle"
                title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
            }
        } else if let engine = error as? PlayerEngineError {
            switch engine {
            case .noSource, .noURL:
                icon = "questionmark.video"
                title = String(localized: "player.error.noVideo.title", defaultValue: "Couldn't open this video")
            }
        } else {
            icon = "exclamationmark.triangle"
            title = String(localized: "player.error.generic.title", defaultValue: "Couldn't start playback")
        }
        errorIcon = icon
        errorTitle = title
        errorMessage = error.localizedDescription
    }

    /// Engine-side terminal error mid-playback (decoder failure,
    /// renderer death, network drop after we'd already handed off).
    /// Different category from start-up errors, playback was running
    /// and stopped, so the headline reads as such.
    func setEnginePlaybackError(message: String) {
        errorIcon = "exclamationmark.triangle"
        errorTitle = String(
            localized: "player.error.playback.title",
            defaultValue: "Playback stopped"
        )
        errorMessage = message
    }

    /// Apply the current `pictureMode` to whichever layer is on screen.
    /// Writes to the engine (which forwards to its native + software
    /// surfaces) AND fires `onPictureModeChanged` so the host's
    /// AVPlayerViewController can mirror the gravity onto AVKit's own
    /// internal AVPlayerLayer. The AVKit-owned layer is what's actually
    /// on screen for the native AVPlayer path, so without the callback
    /// the toggle would be a no-op there.
    func applyPictureMode() {
        switch pictureMode {
        case .original: player.videoGravity = .resizeAspect
        case .fill:     player.videoGravity = .resizeAspectFill
        }
        onPictureModeChanged?(pictureMode)
    }

    /// Fired whenever `applyPictureMode` resolves a new gravity. The
    /// `PlayerHostController` hooks this to update AVPlayerViewController's
    /// own `videoGravity`, which controls the native path's rendering.
    var onPictureModeChanged: ((PlaybackPreferences.PictureMode) -> Void)?

    /// In-player picker change. Mutates the session-local `pictureMode`
    /// and pushes it to the engine. Doesn't persist, the user's
    /// global default lives in `PlaybackPreferences.pictureMode` and
    /// is set from the Settings screen.
    func selectPictureMode(_ mode: PlaybackPreferences.PictureMode) {
        pictureMode = mode
        applyPictureMode()
    }

    /// Seek directly to the start of a chapter. Index is into the
    /// already-sorted `chapters` array, out-of-range calls no-op.
    func selectChapter(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        let target = chapters[index].startSeconds
        Task { [weak self] in await self?.player.seek(to: target) }
    }

    /// Called synchronously before the engine starts an audio-track-switch
    /// reload, while the current AVPlayer is still rendering live frames.
    /// Host uses this to install a freeze-frame snapshot overlay that
    /// hides the ~1 s black frame during pipeline reload (engine teardown
    /// → new producer → new AVPlayer reaches `.playing`).
    /// `PlayerHostController` sets this in `viewDidLoad`.
    var onAudioSwitchBegin: (() -> Void)?

    func selectAudioTrack(id: Int) {
        // No optimistic `activeAudioIndex = id` here; the Combine
        // subscription on `player.$activeAudioTrackIndex` updates the
        // picker once the engine actually settles on the new track.
        // Setting it now would make the picker claim the switch already
        // happened while the pipeline is still mid-reload.
        //
        // `onAudioSwitchBegin` fires synchronously before the async
        // engine reload so the host can snapshot the still-live video
        // surface for the freeze-frame overlay.
        onAudioSwitchBegin?()
        player.selectAudioTrack(index: id)
        // Re-run the auto-subtitle resolution so a manual mid-playback
        // language switch behaves like the initial load did. Without
        // this, switching DE → EN inside the player kept subtitles off
        // even though autoSubtitleForForeignAudio would have turned on
        // German subs at load-time for the same audio choice.
        let language = player.audioTracks.first(where: { $0.id == id })?.language
        applyPreferredSubtitle(forAudioLanguage: language)
    }

    /// Resolves which subtitle track to surface, given the language of
    /// the currently selected audio track:
    ///
    /// 1. Explicit `preferredSubtitleLanguage` always wins.
    /// 2. Otherwise, if `autoSubtitleForForeignAudio` is on AND the
    ///    audio isn't in the preferred audio language, surface subs in
    ///    the preferred audio language, the "Netflix convention":
    ///    German audio missing → English audio plays → German subs on
    ///    top.
    /// 3. No match → leave the current subtitle selection alone (the
    ///    user may have picked one manually; we don't override it on
    ///    a switch back to native audio).
    private func applyPreferredSubtitle(forAudioLanguage audioLanguage: String?) {
        if let explicit = preferences.preferredSubtitleLanguage {
            if let match = bestSubtitleMatch(forLanguage: explicit) {
                selectSubtitleTrack(id: match.index)
            }
            return
        }
        guard preferences.autoSubtitleForForeignAudio,
              let preferredAudio = effectivePreferredAudioLanguage(),
              !Self.languagesMatch(audioLanguage, preferredAudio)
        else { return }
        if let match = bestSubtitleMatch(forLanguage: preferredAudio) {
            selectSubtitleTrack(id: match.index)
        }
    }

    /// Picks the most useful subtitle track in a given language for a
    /// viewer who needs subs to follow the dialog. Plain "full" tracks
    /// win, SDH / CC come next (still cover all dialog), forced tracks
    /// are last-resort because they only translate foreign-language
    /// snippets inside an otherwise-understood audio track, and
    /// signs / songs / commentary tracks are excluded from the
    /// auto-pick entirely since they don't carry general dialog.
    ///
    /// `min(by:)` is stable for ties in Swift, so when multiple
    /// candidates share the best rank the one appearing first in
    /// `subtitleStreams` (which preserves the server's source order)
    /// wins, matching prior behavior for releases where every track
    /// happens to carry the same descriptor.
    private func bestSubtitleMatch(forLanguage language: String) -> MediaStream? {
        let candidates = subtitleStreams.filter {
            Self.languagesMatch($0.language, language)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min(by: {
            Self.subtitleAutoPickRank($0) < Self.subtitleAutoPickRank($1)
        })
    }

    /// Lower rank wins. See `bestSubtitleMatch` for the rationale.
    ///
    /// Encoded as `descriptorRank * 2 + bitmapPenalty` so the
    /// descriptor axis (full > SDH > forced > signs/songs) stays
    /// dominant and codec (text < bitmap) is only a tiebreaker. Full
    /// bitmap still wins over forced text because complete dialog
    /// coverage matters more than appearance customization; full text
    /// wins over full bitmap because the user's font / colour /
    /// background / position / delay settings only apply to text cues
    /// (bitmap cues come pre-rendered from the source).
    private static func subtitleAutoPickRank(_ stream: MediaStream) -> Int {
        let title = stream.title?.lowercased() ?? ""
        let descriptorRank: Int = {
            let isSpecialPurpose = ["signs", "songs", "music", "musik", "commentary"]
                .contains(where: { title.contains($0) })
            if isSpecialPurpose { return 3 }
            let isForced = stream.isForced == true || title.contains("forced")
            if isForced { return 2 }
            let isSDH = ["sdh", "cc", "hearing"]
                .contains(where: { title.contains($0) })
            if isSDH { return 1 }
            return 0
        }()
        let codec = stream.codec?.lowercased() ?? ""
        let isBitmap = ["pgs", "hdmv", "dvb_sub", "dvbsub", "dvd_sub", "dvdsub", "vobsub", "xsub"]
            .contains(where: { codec.contains($0) })
        return descriptorRank * 2 + (isBitmap ? 1 : 0)
    }

    /// Resolves the effective "preferred audio language" used for the
    /// foreign-audio detection. The Settings UI ships an "Auto" choice
    /// that stores nil, without a fallback that path leaves the
    /// foreign-audio guard unable to compare against anything, so a
    /// user who keeps the default never gets auto-subs even when their
    /// system locale clearly indicates the language they speak. We
    /// substitute the device's primary language code so "Auto" still
    /// behaves like "the language my Apple TV is set to".
    private func effectivePreferredAudioLanguage() -> String? {
        if let explicit = preferences.preferredAudioLanguage {
            return explicit
        }
        return Locale.current.language.languageCode?.identifier
    }

    /// Compares two language tags loosely so settings ("ger"), FFmpeg
    /// container metadata ("deu"), and BCP-47 ("de") all line up as
    /// the same language. Without this, the auto-subtitle path was
    /// silently failing for users whose preferred-audio code didn't
    /// match the format the muxer / Jellyfin happened to write into
    /// the stream.
    static func languagesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased() else { return false }
        if a == b { return true }
        return languageSynonyms.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Equivalence classes spanning ISO 639-1, 639-2/T, and 639-2/B
    /// for every language Sodalite ships UI for plus the major ones
    /// users typically have library content in. Anything outside the
    /// table falls back to strict equality, which is fine when both
    /// sides are stamped from the same source.
    private static let languageSynonyms: [Set<String>] = [
        ["de", "deu", "ger"], ["en", "eng"], ["fr", "fra", "fre"],
        ["es", "spa"], ["it", "ita"], ["ja", "jpn"], ["ko", "kor"],
        ["zh", "zho", "chi"], ["pt", "por"], ["ru", "rus"],
        ["nl", "nld", "dut"], ["sv", "swe"], ["da", "dan"],
        ["no", "nor"], ["nb", "nob"], ["nn", "nno"],
        ["fi", "fin"], ["pl", "pol"], ["cs", "ces", "cze"],
        ["hu", "hun"], ["tr", "tur"], ["el", "ell", "gre"],
        ["ar", "ara"], ["he", "heb"], ["hi", "hin"], ["id", "ind"],
        ["th", "tha"], ["vi", "vie"], ["uk", "ukr"], ["ro", "ron", "rum"],
        ["sk", "slk", "slo"], ["hr", "hrv"], ["bg", "bul"],
        ["sr", "srp"], ["pt-br", "por"], ["pt-pt", "por"],
    ]

    // MARK: - Intro Skip

    /// Called from the playback-time Combine subscription. Toggles
    /// `isInsideIntro` so the UI can show/hide the Skip Intro button
    /// without each caller recomputing the range.
    func updateIntroVisibility(time: Double) {
        guard let seg = introSegment else {
            if isInsideIntro { setInsideIntro(false) }
            didSkipCurrentIntro = false
            return
        }

        // Skip-lockout: once the user (or auto-skip) has skipped this
        // intro, keep the pill hidden regardless of currentTime
        // reports. Clears only when the playhead moves below the
        // intro start (deliberate back-scrub past the intro) so a
        // user who scrubs back into the intro range still gets the
        // pill. Without this lockout, stale pre-seek currentTime
        // ticks arriving between `skipIntro`'s synchronous flag flip
        // and the seek landing re-flip isInsideIntro back to true
        // for a frame or two and the user sees the pill briefly
        // re-appear (fade-out → fade-in → fade-out) after the tap.
        if didSkipCurrentIntro {
            if time < seg.startSeconds {
                didSkipCurrentIntro = false
                // fall through to normal evaluation
            } else {
                if isInsideIntro { setInsideIntro(false) }
                return
            }
        }

        // Plugin sometimes reports introStart=0 on episodes with a
        // pre-title cold-open → button would pop up the instant the
        // episode starts, before the titles even play. Give it a tiny
        // lead-in so the button appears with the intro music.
        let inside = time >= max(seg.startSeconds, 0.5)
                  && time < seg.endSeconds - 1   // hide 1s before end

        // Auto-skip path: the very first tick inside the intro fires
        // the skip automatically if the user opted in. Guarded so the
        // skip only happens once per episode even as further ticks
        // arrive before currentTime has actually moved past introEnd.
        if inside && preferences.autoSkipIntro && !didAutoSkipCurrentIntro {
            didAutoSkipCurrentIntro = true
            skipIntro()
            return
        }

        if inside != isInsideIntro {
            setInsideIntro(inside)
        }
    }

    /// Update the flag *and* move focus away from the Skip Intro button
    /// if it just disappeared, otherwise the user would be stuck on a
    /// button that's no longer in the row.
    private func setInsideIntro(_ newValue: Bool) {
        let changed = isInsideIntro != newValue
        isInsideIntro = newValue
        if !newValue && controlsFocus == .skipIntroButton {
            if !player.audioTracks.isEmpty { controlsFocus = .audioButton }
            else if !subtitleStreams.isEmpty { controlsFocus = .subtitleButton }
            else { controlsFocus = .speedButton }
        }
        if changed { onIntroStateChanged?(newValue) }
    }

    /// Jump past the intro. Triggered by the Skip Intro button.
    func skipIntro() {
        guard let seg = introSegment else { return }
        isInsideIntro = false
        didSkipCurrentIntro = true
        Task { [weak self] in
            // seg.endSeconds is absolute source time; seek(to:) is
            // source-PTS based and applies any AVPlayer-clock shift itself.
            await self?.player.seek(to: seg.endSeconds)
            // Lockout only needs to cover the seek-in-flight stale-tick
            // window. Once seek() returns the seek has landed; a brief
            // settle absorbs AVPlayer's post-seek time jitter, then
            // clear so a deliberate backward scrub (into or past the
            // intro range) re-offers the pill. Without this clear the
            // lockout persists for the whole episode and the pill
            // never reappears.
            try? await Task.sleep(for: .milliseconds(500))
            self?.didSkipCurrentIntro = false
        }
    }

    /// Outro equivalent to `updateIntroVisibility`, no Skip Outro UI
    /// button today, so this only has to handle the auto-skip path.
    /// Fires once per episode the moment playback crosses into the
    /// outro range.
    ///
    /// Two variants depending on which combination of preferences is
    /// active:
    ///
    /// - autoSkipOutro + autoplayNextEpisode + next episode ready →
    ///   skip straight to the next episode. Keeping the 10 s
    ///   next-episode countdown on top of a user who explicitly
    ///   asked to skip outros is a contradiction.
    /// - Anything else (e.g. next episode still fetching, or
    ///   autoplayNextEpisode off): seek to outro.endSeconds and let
    ///   the regular next-episode flow pick up from there.
    func updateOutroAutoSkip(time: Double) {
        guard let seg = outroSegment,
              preferences.autoSkipOutro,
              !didAutoSkipCurrentOutro else { return }
        guard time >= seg.startSeconds else { return }
        didAutoSkipCurrentOutro = true

        if preferences.autoplayNextEpisode, nextEpisode != nil {
            Task { @MainActor [weak self] in
                await self?.playNextEpisode()
            }
        } else {
            Task { [weak self] in await self?.player.seek(to: seg.endSeconds) }
        }
    }

    /// Fetch intro + outro markers once on startup. Safe if the server
    /// doesn't expose the endpoint, service returns an empty struct
    /// and the features simply stay off (no Skip Intro button, normal
    /// 30 s fallback trigger for the next-episode overlay).
    func loadEpisodeSegments() async {
        didAutoSkipCurrentIntro = false
        didAutoSkipCurrentOutro = false
        didSkipCurrentIntro = false
        do {
            let segments = try await playbackService.getEpisodeSegments(itemID: item.id)
            introSegment = segments.intro
            outroSegment = segments.outro
        } catch {
            #if DEBUG
            print("[MediaSegments] Fetch failed: \(error)")
            #endif
            introSegment = nil
            outroSegment = nil
        }
    }

    /// Apply the playback speed at the given index in `speedOptions`.
    func selectSpeed(index: Int) {
        let clamped = max(0, min(Self.speedOptions.count - 1, index))
        activeSpeedIndex = clamped
        player.setRate(Self.speedOptions[clamped])
    }

    func selectSubtitleTrack(id: Int?) {
        guard let id else {
            activeSubtitleIndex = nil
            subtitleCues = []
            player.clearSubtitle()
            return
        }
        activeSubtitleIndex = id
        let stream = subtitleStreams.first(where: { $0.index == id })
        let isExternal = stream?.isExternal == true

        if isExternal {
            // Sidecar file (.srt / .ass / .vtt next to the media).
            // Hand the URL to the engine, it fetches the file once
            // and decodes it via FFmpeg, no host-side SRTParser. The
            // resulting cues land on `engine.subtitleCues` and the
            // mirror sink picks them up.
            if let url = playbackService.buildSubtitleURL(
                itemID: item.id,
                mediaSourceID: mediaSourceID,
                streamIndex: id,
                format: stream?.codec ?? "srt"
            ) {
                player.selectSidecarSubtitle(url: url)
                subtitleCues = []
            } else {
                player.clearSubtitle()
                subtitleCues = []
            }
        } else if activePlayMethod != .transcode {
            // Embedded stream on direct play / direct stream, engine
            // streams cues from packets already flowing through the
            // main demux loop, both for text codecs (SubRip / ASS /
            // WebVTT / mov_text) and bitmap codecs (PGS / DVB / HDMV
            // PGS). No second connection, no server extraction.
            player.selectSubtitleTrack(index: id)
            subtitleCues = player.subtitleCues
        } else {
            // Transcoded session, HLS rewrites stream indices so
            // the engine can't reach the source subtitle. Fall back
            // to the legacy server-extracted SRT loader, which only
            // works for text codecs.
            player.clearSubtitle()
            subtitleCues = []
            Task { await loadSubtitles(streamIndex: id) }
        }
    }

    private static let subtitleLog = Logger(
        subsystem: "de.superuser404.Sodalite",
        category: "Subtitles"
    )

    private func loadSubtitles(streamIndex: Int) async {
        let stream = subtitleStreams.first(where: { $0.index == streamIndex })
        Self.subtitleLog.notice(
            "loadSubtitles streamIndex=\(streamIndex, privacy: .public) codec=\(stream?.codec ?? "nil", privacy: .public) lang=\(stream?.language ?? "nil", privacy: .public)"
        )

        guard let url = playbackService.buildSubtitleURL(
            itemID: item.id,
            mediaSourceID: mediaSourceID,
            streamIndex: streamIndex,
            format: "srt"
        ) else {
            Self.subtitleLog.notice("→ failed to build URL")
            return
        }

        // The first hit on a 4K UHD container can take several
        // seconds, Jellyfin lazy-extracts the sub via FFmpeg and
        // a freshly-loaded server hasn't cached anything yet. Two
        // attempts with a generous budget catches both the slow-
        // extraction case (long timeout buys it through) and the
        // odd transient (retry hits the now-cached payload).
        var request = URLRequest(url: url)
        request.timeoutInterval = 120

        for attempt in 1...2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) HTTP \(http.statusCode, privacy: .public)")
                    if attempt == 2 { return }
                    continue
                }
                guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) empty payload")
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let cues = SRTParser.parse(content)
                if cues.isEmpty {
                    Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) parsed 0 cues from \(content.count, privacy: .public) bytes")
                    if attempt == 2 { return }
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                subtitleCues = cues
                Self.subtitleLog.notice("→ loaded \(cues.count, privacy: .public) cues on attempt \(attempt, privacy: .public)")
                return
            } catch {
                Self.subtitleLog.notice("→ attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == 2 { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Helpers

    func showControlsTemporarily() {
        showControls = true
        scheduleControlsHide()
    }

    func hideControls() {
        showControls = false
        controlsFocus = .progressBar
        trackDropdown = .none
    }

    func scheduleControlsHide() {
        controlsTimer?.cancel()
        guard isPlaying else { return }
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            hideControls()
        }
    }

    func formatSeconds(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

enum PlayerEngineError: LocalizedError {
    case noSource
    case noURL

    var errorDescription: String? {
        switch self {
        case .noSource:
            String(
                localized: "player.error.noSource",
                defaultValue: "The server didn't return any media source for this item."
            )
        case .noURL:
            String(
                localized: "player.error.noURL",
                defaultValue: "Couldn't build a stream URL for this item."
            )
        }
    }
}
