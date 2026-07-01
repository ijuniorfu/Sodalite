import Foundation
import Combine
import Observation
import AetherEngine
import SwiftAssRenderer
import AVKit
import UIKit
import os

/// Bridges AetherEngine with Jellyfin session reporting and the custom tvOS player UI.
/// Combine subscriptions observe the engine's @Published properties (no polling timers,
/// avoids AttributeGraph cycles). Split across +Scrubbing / +NextEpisode / +SessionReporting.
@Observable
@MainActor
final class PlayerViewModel {

    // MARK: - UI State

    var isLoading = true
    /// True while the host is bringing a session up (fetching playback info, calling `player.load()`, or
    /// running a live retune), independent of the engine phase. ORed with `playbackPhase` so the pre-engine
    /// load window still shows the spinner (AetherEngine#85). `didSet` keeps `isLoading` in sync. Not private:
    /// the live retune path in the `+Live` extension (separate file) drives it.
    var hostLoadActive = false {
        didSet { recomputeLoadingIndicator() }
    }
    /// Guards against stacking the live cold-transcode debounce recheck.
    private var scheduledLiveSpinnerRecheck = false
    var errorMessage: String?
    /// SF Symbol for the active error, set with `errorMessage` via `setError(from:)`.
    var errorIcon: String?
    /// Localised error headline above `errorMessage` in the overlay.
    var errorTitle: String?
    var isPlaying = false
    var showControls = false

    var currentTime: String = "00:00"
    var totalTime: String = "00:00"
    var remainingTime: String = "-00:00"
    var progress: Float = 0

    var playbackTime: Double = 0

    /// source-PTS of displayed frame, mirrored from `AetherEngine.sourceTime`; native-path
    /// AVPlayer clock = source_pts - producer.videoShiftPts, so side-demuxer cues sync off this.
    /// Equals playbackTime on the SW path.
    var subtitleTime: Double = 0

    var isScrubbing = false
    var scrubProgress: Float = 0
    var scrubTime: String = "00:00"
    var displayedProgress: Float { isScrubbing ? scrubProgress : progress }
    var scrubStartProgress: Float = 0

    var controlsFocus: ControlsFocus = .progressBar
    var trackDropdown: TrackDropdown = .none

    // MARK: Subtitle search (Feature #4)

    enum SubtitleSearchState: Equatable {
        case idle
        case loading
        case results([RemoteSubtitleInfo])
        case empty
        case downloading(id: String)
        case error(String)
        /// Download POST accepted but track not attached by the time polling stopped (slow CDN).
        /// Carries the requested subtitle + pre-download stream-index snapshot so "Try again"
        /// re-checks without re-downloading. `message` is the localized pending copy.
        case downloadTimedOut(info: RemoteSubtitleInfo, before: Set<Int>, message: String)
    }

    var subtitleSearchVisible = false
    var subtitleSearchState: SubtitleSearchState = .idle
    /// 3-letter ISO language for the next search; seeded from preferred subtitle, then device language.
    var subtitleSearchLanguage: String = "eng"

    /// Highlighted element of the subtitle-search overlay. Display-only in SubtitleSearchView;
    /// driven by PlayerHostController press handlers.
    enum SubtitleSearchFocus: Equatable {
        case language(Int)   // index into subtitleSearchLanguageOptions
        case result(Int)     // index into the current results
        case retry           // the "Try again" button in the timed-out state
    }
    var subtitleSearchFocus: SubtitleSearchFocus = .language(0)

    /// Delete-confirmation flow for an external subtitle (hold-to-delete on its dropdown row).
    /// Host-driven overlay, display-only in SubtitleDeletePromptView. Feature #4.
    enum SubtitleDeleteState: Equatable {
        case hidden
        case confirm(streamIndex: Int)
        case deleting
        case error(String)
    }
    enum SubtitleDeleteButton { case cancel, delete }
    var subtitleDeleteState: SubtitleDeleteState = .hidden
    var subtitleDeleteFocus: SubtitleDeleteButton = .cancel
    var isSubtitleDeletePromptVisible: Bool {
        if case .hidden = subtitleDeleteState { return false }
        return true
    }

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
        // Live-only "Return to Live" pill (LiveTransportBar); Up from the live scrubber when
        // behind the live edge, Select fires returnToLiveEdge(). VOD button row N/A for live.
        case returnToLiveButton
    }

    /// Stats-for-nerds side panel mount flag. While true it captures all remote presses
    /// (scroll, dismiss) so the player UI behind it stays inert.
    var showStatsOverlay: Bool = false {
        didSet {
            // Reset scroll cursor on open so the user always starts at the first section.
            if showStatsOverlay && !oldValue {
                statsSectionIndex = 0
            }
        }
    }

    /// Section-anchor cursor for the stats panel; up/down shifts it, StatsOverlayView watches
    /// via `scrollTo`. Clamped by `statsSectionAnchors.count`.
    var statsSectionIndex: Int = 0

    /// Ordered anchor IDs per stats section; up/down cursor jumps page through them.
    static let statsSectionAnchors: [String] = [
        "stats.section.live",       // 0: always shown when stats on
        "stats.section.playback",   // 1
        "stats.section.video",      // 2
        "stats.section.audio",      // 3
        "stats.section.subtitle",   // 4
        "stats.section.file",       // 5
        "stats.section.engine",     // 6: gated by showEngineDiagnostics
        "stats.section.buffer",     // 7: gated by showEngineDiagnostics
        "stats.section.network",    // 8: gated by showEngineDiagnostics
    ]

    enum TrackDropdown: Equatable {
        case none
        case chapter(highlighted: Int)  // index into chapters
        case episode(highlighted: Int)  // index into seasonEpisodes
        case audio(highlighted: Int)   // index into displayAudioTracks
        case subtitle(highlighted: Int) // index into subtitle items (0=Off, 1..=displaySubtitleStreams)
        case secondarySubtitle(highlighted: Int) // 0=Off, 1..=secondarySubtitleCandidates
        case speed(highlighted: Int)    // index into PlayerViewModel.speedOptions
        case picture(highlighted: Int)  // index into PlaybackPreferences.PictureMode.allCases
    }

    var isDropdownOpen: Bool { trackDropdown != .none }

    /// Playback speed choices; index 2 = 1.0x (matches native tvOS player's stepped set).
    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    var activeSpeedIndex: Int = 2

    // Tracks
    var subtitleCues: [SubtitleCue] = [] {
        didSet {
            subtitleMaxCueDuration = subtitleCues.reduce(60.0) {
                max($0, $1.endTime - $1.startTime)
            }
        }
    }
    /// Longest cue duration (floor 60s) bounding the overlay's active-cue walk-back; a fixed
    /// bound dropped long PGS cues (unbounded endTimes), engine prunes bitmap cues to 300s.
    var subtitleMaxCueDuration: Double = 60
    var activeAudioIndex: Int?
    var activeSubtitleIndex: Int?

    /// Secondary companion subtitle cues (issue #47), mirrored from `engine.secondarySubtitleCues`.
    var secondarySubtitleCues: [SubtitleCue] = [] {
        didSet {
            secondarySubtitleMaxCueDuration = secondarySubtitleCues.reduce(60.0) {
                max($0, $1.endTime - $1.startTime)
            }
        }
    }
    var secondarySubtitleMaxCueDuration: Double = 60
    var activeSecondarySubtitleIndex: Int?

    /// Audio tracks in picker order (container-default first); picker UI indexes here, not `player.audioTracks`.
    var displayAudioTracks: [TrackInfo] {
        let tracks = player.audioTracks
        return tracks.filter { $0.isDefault } + tracks.filter { !$0.isDefault }
    }

    /// Subtitle streams in picker order (Jellyfin-default first); picker UI indexes here with "Off" at 0, not `subtitleStreams`.
    var displaySubtitleStreams: [MediaStream] {
        let streams = subtitleStreams
        return streams.filter { $0.isDefault == true } + streams.filter { $0.isDefault != true }
    }

    /// In-player subtitle-search reachability; VOD-only (live has no searchable library item).
    /// Also shows the subtitle button on files with zero tracks so the download entry exists (issue #15).
    var supportsSubtitleSearch: Bool { !isLiveSession }

    /// Streams eligible as SECONDARY track: text codecs only (bitmap can't stack as a companion line),
    /// never the active primary. Picker order matches `displaySubtitleStreams`.
    var secondarySubtitleCandidates: [MediaStream] {
        let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvbsub", "dvb_subtitle", "dvdsub", "dvd_subtitle", "xsub"]
        return displaySubtitleStreams.filter { stream in
            if stream.index == activeSubtitleIndex { return false }
            let codec = stream.codec?.lowercased() ?? ""
            return !bitmapCodecs.contains(codec)
        }
    }

    /// Current season's episodes sorted by indexNumber, populated lazily after startPlayback for
    /// the transport-bar episode picker. Empty for movies/single-episode; TransportBar hides button at count <= 1.
    var seasonEpisodes: [JellyfinItem] = []

    /// Source-container chapters from `item.chapters`, sorted by start position so the scrub-bar
    /// and dropdown iterate in playback order. TransportBar hides the button at count <= 1.
    var chapters: [ChapterInfo] = []

    /// Original unsorted `item.chapters` index per sorted `chapters` entry (parallel array). The
    /// server's chapter-image endpoint keys on the unsorted container position, so the sort above
    /// would fetch the wrong image without this remap.
    @ObservationIgnored private var chapterImageIndices: [Int] = []

    /// Session-local picture-fill mode, seeded from `PlaybackPreferences.pictureMode` at startPlayback.
    /// Transient override, not persisted; settings owns the global default.
    var pictureMode: PlaybackPreferences.PictureMode = .original

    var videoFormat: VideoFormat = .sdr

    // MARK: - Shuffle / play queue

    /// When non-empty, playback advances through this shuffled list instead of the series
    /// successor; current item is `playQueue[queueIndex]`. Reuses the next-episode reload-in-place
    /// path to keep the engine AVPlayer alive across items (issue #15).
    var playQueue: [JellyfinItem] = []
    /// Index of the current item in `playQueue` (launch item = 0; `playNextEpisode()` increments).
    var queueIndex: Int = 0

    var isQueuePlayback: Bool { !playQueue.isEmpty }

    var nextEpisode: JellyfinItem?
    var showNextEpisodeOverlay = false
    var nextEpisodeCountdown = 10
    /// Fired once at demux EOF when there's no next episode; PlayerHostController routes it to the
    /// Menu dismiss path. Without it the player sits on a black frame with no focus target.
    var onPlaybackReachedEnd: (() -> Void)?

    var isCountdownActive = false
    var nextEpisodeTimer: Task<Void, Never>?
    var hasFetchedNextEpisode = false
    var nextEpisodeCancelled = false

    /// Last `currentTime` seen by the next-episode hook, used to detect backward scrubs so the
    /// overlay resets; without it the show-logic is one-way and the overlay sticks on screen.
    var lastPlaybackTimeForNextEpisode: Double = 0

    // Intro + outro markers, both from Jellyfin Media Segments / intro-skipper plugin in one call.
    var introSegment: MediaSegment?
    var outroSegment: MediaSegment?
    /// True while playbackTime is inside the intro; shows Skip Intro even when controls are closed.
    var isInsideIntro: Bool = false
    /// Set once per episode after auto-skip fires; keeps the time subscriber from re-triggering
    /// before the seek moves currentTime past introEnd.
    var didAutoSkipCurrentIntro: Bool = false
    /// Outro equivalent of `didAutoSkipCurrentIntro`; prevents repeat auto-skip while currentTime
    /// ticks toward outro.endSeconds.
    var didAutoSkipCurrentOutro: Bool = false
    /// Skip-lockout latch: while set, `updateIntroVisibility` refuses to re-flip `isInsideIntro` true
    /// so stale pre-seek ticks (between skipIntro's flag flip and the seek landing) can't revive the
    /// pill mid-fade. Cleared 500ms after `player.seek` returns (absorbs post-seek jitter), on episode
    /// change, and as a fast path when a tick arrives with `time < seg.startSeconds`.
    var didSkipCurrentIntro: Bool = false

    // MARK: - Dependencies

    var item: JellyfinItem
    let player: AetherEngine

    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    var startFromBeginning: Bool
    var cachedPlaybackInfo: PlaybackInfoResponse?
    let preferences: PlaybackPreferences

    /// When set, `startPlayback()` selects the matching PlaybackInfo source instead of first.
    /// Nil keeps default-first. Set by the detail-view version picker.
    let preferredMediaSourceID: String?

    /// Scrub-preview thumbnail provider over the session FrameExtractor; configured in startPlayback,
    /// reset in stopPlayback.
    let scrubPreview: ScrubPreviewProvider

    /// Session-scoped frame extractor (static stream URL); built in startPlayback, shut down in
    /// stopPlayback. Shared by `scrubPreview` and `chapterThumbnail(forIndex:)`.
    @ObservationIgnored private var frameExtractor: FrameExtractor?

    /// A chapter still. Prefers the Jellyfin-rendered chapter image (when `imageTag` is set, post
    /// "Chapter image extraction" task): pre-rendered, cheap, reliable. Falls back to decoding the
    /// still ourselves, which needs a deep random-access seek that flakes deeper into the file
    /// (root of issue #21). Nil if neither yields an image or index is invalid.
    func chapterThumbnail(forIndex index: Int) async -> CGImage? {
        guard chapters.indices.contains(index) else { return nil }
        let chapter = chapters[index]
        if let tag = chapter.imageTag, !tag.isEmpty,
           let url = playbackService.buildChapterImageURL(
               itemID: item.id,
               chapterIndex: chapterImageIndices[index],
               imageTag: tag,
               maxWidth: 320
           ),
           let image = await Self.loadServerChapterImage(from: url) {
            return image
        }
        guard let frameExtractor else { return nil }
        return await frameExtractor.thumbnail(at: chapter.startSeconds, maxWidth: 320)
    }

    /// Fetches + decodes a server chapter image via the shared `ImageCache` (memory-only). Auth rides
    /// the URL's `api_key` query so no header needed; `nonisolated static` runs the decode off MainActor.
    nonisolated private static func loadServerChapterImage(from url: URL) async -> CGImage? {
        if let cached = ImageCache.shared.image(for: url) { return cached.cgImage }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            let prepared = image.preparingForDisplay() ?? image
            ImageCache.shared.store(prepared, for: url)
            return prepared.cgImage
        } catch {
            return nil
        }
    }

    /// Fetch a trickplay tile sprite (cached whole, keyed by tile URL) and crop `crop` out of it.
    /// Off-MainActor (network + decode), mirroring loadServerChapterImage. The MainActor caller
    /// resolves the tile URL + crop rect from the TrickplayTileSet first. Nil on fetch failure or
    /// an out-of-bounds crop.
    nonisolated private static func fetchTrickplayCrop(from url: URL, crop: CGRect) async -> CGImage? {
        let tileImage: UIImage
        if let cached = ImageCache.shared.image(for: url) {
            tileImage = cached
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let image = UIImage(data: data) else { return nil }
                let prepared = image.preparingForDisplay() ?? image
                ImageCache.shared.store(prepared, for: url)
                tileImage = prepared
            } catch {
                return nil
            }
        }
        guard let cg = tileImage.cgImage else { return nil }
        guard crop.maxX <= CGFloat(cg.width), crop.maxY <= CGFloat(cg.height),
              let cropped = cg.cropping(to: crop) else { return nil }
        return cropped
    }

    /// Use server trickplay only when the user opted in AND the item actually has tiles.
    nonisolated static func shouldUseServerTrickplay(preferServer: Bool, tileSet: TrickplayTileSet?) -> Bool {
        preferServer && tileSet != nil
    }

    /// Open-time routing-probe budget for the engine on remote direct-play / direct-stream sources (#68).
    /// Direct play and direct stream serve the original container, whose sparse HDMV PGS tracks and cover-art
    /// attachments otherwise drag the engine's `find_stream_info` to the full 50 MB / 60 s default, adding
    /// ~13-14 s before first frame over a slow connection. Video and HDR/DV signaling resolve from the first
    /// packets and every audio track interleaves early, so a 16 MB / 10 s cap keeps the audio picker complete
    /// (it reads `player.audioTracks`, which comes from this probe) while skipping the PGS tail. The subtitle
    /// picker is built from Jellyfin `MediaStreams`, and bitmap tracks select through the engine's own
    /// full-budget side-demuxer by absolute container index, so a routing probe that skips a PGS track loses
    /// nothing. Transcode sessions get a clean HLS stream with no sparse-track tail, so they keep the default.
    nonisolated static func remoteDirectPlayProbeBudget(method: PlayMethod, source: PlaybackMediaSource) -> (probesize: Int64?, maxAnalyzeDuration: Int64?) {
        switch method {
        case .transcode:
            return (nil, nil)
        case .directPlay, .directStream:
            // Live / infinite / external-URL sources (e.g. a remote .strm IPTV stream) have no fixed size and a
            // continuous, often Range-ignoring body; the sparse-tail cap starves find_stream_info and the source
            // fails or crashes the engine probe (issue #31). Only cap sized server-file remuxes (the sparse
            // PGS / cover-art tail case the cap was added for).
            let isStreaming = source.size == nil || (source.path?.hasPrefix("http") ?? false)
            return isStreaming ? (nil, nil) : (16 * 1024 * 1024, 10 * 1_000_000)
        }
    }

    // MARK: - Internal State

    var cancellables = Set<AnyCancellable>()
    var progressTimer: Task<Void, Never>?
    var progressReportOnDemandTask: Task<Void, Never>?
    var controlsTimer: Task<Void, Never>?
    /// In-flight continuous (hold-to-seek) scrub task; non-nil while left/right is held, advances
    /// scrubProgress with acceleration until release (see PlayerViewModel+Scrubbing).
    var continuousSeekTask: Task<Void, Never>?
    /// In-flight initial-launch task (see `beginPlayback`), held so a back-press during the spinner
    /// can cancel it before `player.load()`; untracked it would resume after stopPlayback's
    /// player.stop() and restart playback behind a dismissed player (audio runs until app restart).
    var loadTask: Task<Void, Never>?
    /// Latched by `stopPlayback()`; startPlayback resets it at entry and re-checks after every await
    /// so a teardown racing an in-flight load (incl. next-episode / season-picker tasks, not loadTask
    /// and thus uncancellable) still bails before or stops right after `player.load()`.
    var isTearingDown = false
    var hasReportedStart = false
    var hasStartedPlaying = false
    /// Resume position, used as minimum for progress reports so Jellyfin doesn't reset progress on early stop.
    var resumePositionTicks: Int64 = 0
    var mediaSourceID: String = ""
    var playSessionID: String?
    var activePlayMethod: PlayMethod = .directPlay
    var subtitleStreams: [MediaStream] = []
    /// Lowercased Jellyfin codec of the active subtitle ("ass"/"ssa"/"subrip"/...), nil when off.
    /// The overlay reads it to gate the raw-ASS-event-line stripper.
    var activeSubtitleCodec: String?
    /// Styled ASS rendering bridge, active only while the selected embedded track is ASS/SSA
    /// (AetherEngine#30). Lazy to capture `player`; @ObservationIgnored, observable surface is `assRenderer`.
    @ObservationIgnored private lazy var assCoordinator = ASSRenderCoordinator(player: player)
    /// Observable mirror of `assCoordinator.renderer` (coordinator isn't @Observable), updated at
    /// every activate/deactivate so the overlay swaps between styled ASS and cue path reactively.
    private(set) var assRenderer: AssSubtitlesRenderer?
    /// One-shot observation of `engine.sidecarASSHeader` for styled ASS on EXTERNAL .ass/.ssa sidecars
    /// (AetherEngine#48): sidecar headers publish asynchronously (unlike embedded TrackInfo), so
    /// activation waits for the first non-nil value. Cancelled on track change / deactivate.
    @ObservationIgnored private var sidecarASSHeaderCancellable: AnyCancellable?
    /// In-flight transcode-path SRT load (server extraction can take up to 120s). Cancelled when the
    /// user switches or disables the subtitle track so a stale load can't clobber the new selection.
    @ObservationIgnored private var subtitleLoadTask: Task<Void, Never>?
    /// Coordinator reload pre-announcements; the overlay's frame view subscribes so reload-induced
    /// transient nil frames never blank a visible subtitle. Stable for the VM lifetime.
    var assReloadSignal: PassthroughSubject<Void, Never> { assCoordinator.reloadSignal }

    // MARK: - Live TV

    /// True for a live channel (not VOD); gates DVR transport, disables resume / chapters / next-episode.
    private(set) var isLiveSession = false
    /// Jellyfin tuner handle for the current live stream; captured on load, released on teardown. Nil for VOD.
    var activeLiveStreamID: String?
    /// Live-edge mirror fields, populated by PlayerViewModel+Live from the engine's live surfaces.
    var liveSeekableRange: ClosedRange<Double>?
    var isAtLiveEdge: Bool = true
    var behindLiveSeconds: Double = 0
    /// Channel for live sessions. Nil for VOD.
    let liveChannel: JellyfinChannel?
    /// Live-TV service for tuner lifecycle (PlayerViewModel+Live). Nil for VOD.
    let liveTvService: JellyfinLiveTvServiceProtocol?
    /// Latched by `observeLiveEdge()` so a retune (re-runs `loadLiveStream`) can't stack duplicate sinks.
    var hasLiveEdgeObservers = false
    /// Retune guard for `handleLiveSourceReset`: in-flight retune swallows further resets; per-session
    /// cap + min spacing stops a server replaying on EVERY reconnect from looping retunes forever.
    var liveRetuneInFlight = false
    var lastLiveRetuneAt: Date?
    var liveRetuneCount = 0
    /// When live first reached .playing; gates startup-window spinner masking (cold transcodes stall
    /// once right after start while the server catches up to real time).
    var liveFirstPlayingAt: Date?
    /// True while this live session plays the tuner upstream directly (HLS ingest), Jellyfin out of the path.
    var usedDirectLivePath = false
    /// Latch: the once-per-session direct-to-Jellyfin fallback has been consumed.
    var didAttemptLiveFallback = false

    init(
        item: JellyfinItem,
        startFromBeginning: Bool,
        playbackService: JellyfinPlaybackServiceProtocol,
        userID: String,
        preferences: PlaybackPreferences,
        cachedPlaybackInfo: PlaybackInfoResponse? = nil,
        preferredMediaSourceID: String? = nil,
        playQueue: [JellyfinItem] = [],
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
        self.preferredMediaSourceID = preferredMediaSourceID
        self.playQueue = playQueue
        self.queueIndex = 0
        self.isLiveSession = isLiveSession
        self.liveChannel = liveChannel
        self.liveTvService = liveTvService
    }

    // MARK: - Lifecycle

    /// Initial-launch entry point (host VC, modal appear), via a tracked task so a back-press during
    /// the spinner cancels the in-flight startPlayback (engine throws CancellationError out of
    /// player.load()) before it touches the shared engine.
    func beginPlayback() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.startPlayback() }
    }

    func startPlayback() async {
        isTearingDown = false
        hostLoadActive = true
        clearError()
        // Sort chapters defensively: API documents start-position order but some legacy taggers emit out of sequence.
        let orderedChapters = (item.chapters ?? [])
            .enumerated()
            .sorted { $0.element.startPositionTicks < $1.element.startPositionTicks }
        chapters = orderedChapters.map(\.element)
        chapterImageIndices = orderedChapters.map(\.offset)
        // Reset to the global default each session so in-player overrides don't bleed across episodes/movies.
        pictureMode = preferences.pictureMode
        applyPictureMode()
        #if DEBUG
        print("[PlayerVM] startPlayback: item=\(item.name), seriesId=\(item.seriesId ?? "nil"), type=\(item.type), chapters=\(chapters.count)")
        #endif

        // Now Playing is driven by AVKit's internal session (auto-activates with showsPlaybackControls
        // + an assigned AVPlayer, reads AVPlayerItem.externalMetadata).

        do {
            // Live channels take a dedicated load path (open tuner, infinite live MediaSource, isLive
            // + DVR window). VOD wiring below (resume, chapters, intro markers, episode picker) doesn't
            // apply; the shared post-load steps are duplicated here on purpose to keep the VOD path untouched.
            if isLiveSession {
                stageInitialNowPlayingMetadata()
                usedDirectLivePath = false
                didAttemptLiveFallback = false
                try await loadLiveStream()
                if Task.isCancelled || isTearingDown {
                    player.stop()
                    // loadLiveStream() may have opened a tuner before cancel landed; release so server doesn't leak.
                    releaseLiveTunerIfNeeded()
                    hostLoadActive = false
                    return
                }
                // The engine picked the preferred-language audio on the first frame (#72), so there is
                // no live selectAudioTrack reload here (it used to misfire on single-track channels:
                // Das Erste, frozen frame). Read its pick to drive the matching subtitle.
                let chosenAudio = player.audioTracks.first(where: { $0.id == player.activeAudioTrackIndex })
                applyPreferredSubtitle(forAudioLanguage: chosenAudio?.language)
                hostLoadActive = false
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

            let source = info.mediaSources.first(where: { $0.id == preferredMediaSourceID })
                ?? info.mediaSources.first
            guard let source else {
                throw PlayerEngineError.noSource
            }
            mediaSourceID = source.id

            #if DEBUG
            print("[PlayerViewModel] Source: container=\(source.container ?? "nil"), directPlay=\(source.supportsDirectPlay ?? false), directStream=\(source.supportsDirectStream ?? false), transcoding=\(source.supportsTranscoding ?? false)")
            if let tURL = source.transcodingUrl {
                print("[PlayerViewModel] TranscodingURL: \(tURL.prefix(120))...")
            }
            #endif

            // Keep all subtitle tracks: bitmap codecs (PGS/HDMV/DVB/DVD) now render as CGImage so they
            // belong in the picker, and forced tracks stay (many releases mark every track forced). Dedupe
            // keys on forced/signs/sdh descriptors so distinct same-language tracks don't collapse.
            subtitleStreams = Self.dedupedSubtitleStreams(from: source.mediaStreams)

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

            // Scrub preview + chapter thumbnails decode stills from the original file (isStatic:true)
            // regardless of playback method, so transcode sessions still get a preview.
            if let previewURL = playbackService.buildStreamURL(
                itemID: item.id, mediaSourceID: source.id,
                container: source.container, isStatic: true
            ) {
                frameExtractor = FrameExtractor(url: previewURL, httpHeaders: [:])
            } else {
                frameExtractor = nil
            }
            let trickplayTileSet = TrickplayTileSet(
                trickplay: item.trickplay, mediaSourceID: source.id, targetWidth: 320)
            if Self.shouldUseServerTrickplay(
                preferServer: preferences.preferServerTrickplay, tileSet: trickplayTileSet),
               let tileSet = trickplayTileSet {
                let itemID = item.id
                let service = playbackService
                scrubPreview.configure(
                    serverThumbnail: { seconds in
                        // MainActor: resolve tile index + crop, then hop off-actor to fetch/decode.
                        guard let placement = tileSet.tile(forSeconds: seconds),
                              let url = service.buildTrickplayTileURL(
                                  itemID: itemID, width: tileSet.width, tileIndex: placement.tileIndex)
                        else { return nil }
                        return await Self.fetchTrickplayCrop(from: url, crop: placement.crop)
                    },
                    enabled: preferences.showScrubPreview
                )
            } else {
                scrubPreview.configure(
                    extractor: frameExtractor,
                    enabled: preferences.showScrubPreview
                )
            }

            let startPos: Double?
            if !startFromBeginning,
               let ticks = item.userData?.playbackPositionTicks, ticks > 0 {
                startPos = ticks.ticksToSeconds
                resumePositionTicks = ticks
            } else {
                startPos = nil
                resumePositionTicks = 0
            }

            // Stage title/description as externalMetadata BEFORE engine.load (applied pre-replaceCurrentItem);
            // cover follows async post-load via refreshExternalMetadataWithArtwork(); AVKit re-reads it.
            stageInitialNowPlayingMetadata()

            // Bail before touching the shared engine if torn down while awaiting playback info, else
            // this in-flight task calls player.load() AFTER stopPlayback's player.stop() and restarts
            // playback with no UI to dismiss it (audio runs until app restart).
            if Task.isCancelled || isTearingDown {
                hostLoadActive = false
                return
            }

            // Single load path: engine picks native AVPlayer or its sample-buffer fallback (VP9/AV1,
            // DV P7). Format detection, HDMI HDR handshake, layer ownership, refresh-rate matching all
            // inside engine.load now.
            LogTap.shared.note("[PlayerVM] engine.load url=\(url.absoluteString)")
            // matchContentEnabled (tvOS Match Content master toggle) + panelIsInHDRMode (EDR active)
            // feed the engine's master-vs-media playlist routing: panel-in-HDR makes master routing safe
            // regardless of the match flag (SUPPLEMENTAL-CODECS=dvh1 upgrade per AetherEngine#4), else
            // HDR sources fall back to media to avoid AVPlayer asset-open -11848 on an SDR panel.
            // AVKit is the sole criteria writer (appliesPreferredDisplayCriteriaAutomatically=true on
            // PlayerHostController); it reads live AVPlayerItem.formatDescription (dvcC from the fMP4
            // sample entry) and writes the DV criteria, engine only GATES play() on the panel handshake
            // (AetherEngine 5d60dbb). See PlayerHostController init for full rationale.
            // Cap the engine's open-time probe on sized server-file direct-play/-stream remuxes so a sparse PGS
            // / cover-art tail doesn't drag find_stream_info to the 50 MB default before first frame (#68).
            // Live/infinite/external-URL sources (remote .strm IPTV) are exempt: the cap truncates their
            // continuous probe and crashes the load (#31). Safe: the subtitle picker selects via the engine's
            // full-budget side-demuxer.
            let probeBudget = Self.remoteDirectPlayProbeBudget(method: activePlayMethod, source: source)
            // Hand the language preference to the engine so it picks the audio track on the first frame
            // from its single probe (#72), instead of us reloading via selectAudioTrack after load.
            let preferredAudio = effectivePreferredAudioLanguage()
            try await player.load(
                url: url,
                startPosition: startPos,
                options: LoadOptions(
                    suppressDisplayCriteria: false,
                    matchContentEnabled: Self.matchDynamicRangeEnabled,
                    panelIsInHDRMode: Self.panelIsInHDRMode,
                    audioBridgeMode: preferences.audioBridgeMode,
                    // Raw ASS event lines for the styled path; only affects ASS/SSA cue content.
                    preserveASSMarkup: true,
                    // PROBE (Sodalite#32): serve a WebVTT rendition with eager readers; the engine marks the
                    // rendition matching nativeSubtitlePreferredLanguages DEFAULT=YES (required for a host-
                    // selected legible track to render) and exposes it as nativeSubtitleDefaultOrdinal.
                    prepareNativeSubtitles: Self.nativePiPSubtitleProbe,
                    eagerNativeSubtitleReaders: Self.nativePiPSubtitleProbe,
                    nativeSubtitlePreferredLanguages: Self.nativePiPSubtitleProbe
                        ? (preferences.preferredSubtitleLanguage.map { [$0] } ?? [])
                        : [],
                    probesize: probeBudget.probesize,
                    maxAnalyzeDuration: probeBudget.maxAnalyzeDuration,
                    preferredAudioLanguages: preferredAudio.map { [$0] } ?? []
                )
            )

            // Teardown can land between load() returning and observation wiring (back-press just as the
            // asset opened); stop the engine we just started so nothing plays behind a dismissed player.
            if Task.isCancelled || isTearingDown {
                player.stop()
                hostLoadActive = false
                return
            }

            totalTime = formatSeconds(effectiveDuration)
            // The engine resolved the preferred-language audio on the first frame (#72), so there is no
            // selectAudioTrack reload here; read what it picked to drive the matching subtitle.
            let chosenAudio = player.audioTracks.first(where: { $0.id == player.activeAudioTrackIndex })
            if Self.nativePiPSubtitleProbe {
                // PROBE (Sodalite#32): iOS uses native AVKit player UI; the USER selects the subtitle via AVKit's
                // native CC menu. A deliberate user selection is NOT reconciled away by AVSmartSubtitlesController
                // (unlike our programmatic select, which it disabled as mute-only over the loopback). We only
                // serve the WebVTT renditions + eager readers so the menu lists them and cues are ready.
                LogTap.shared.note("[PiPDiag] host: native-UI mode, user picks via AVKit CC menu; nativeTracks=\(player.nativeSubtitleTracks.map { $0.language ?? "?" })")
                // AVKit auto-selects a persisted subtitle at load, but its legible renderer does NOT attach for a
                // selection made before the view/pipeline is established (device: renders nothing until a seek,
                // and a seek over our loopback is a disruptive producer restart -> black frame). A programmatic
                // deselect/reselect does not attach it either. So DON'T let AVKit auto-select at load: start subs
                // off and let the user turn them on during playback via the CC menu (that DOES attach the
                // renderer -> the working common case). Reliable rendering without a disruptive seek.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await self?.disablePersistedLegibleAtLoad()
                }
            } else {
                applyPreferredSubtitle(forAudioLanguage: chosenAudio?.language)
            }

            hostLoadActive = false
            isPlaying = true

            startObserving()
            // Cover fetch is async post-load; engine writes externalMetadata to the live item and the session republishes.
            Task { [weak self] in await self?.refreshExternalMetadataWithArtwork() }
            await reportStart()
            startProgressReporting()

            // Background fetch, doesn't block start; the next tick flips isInsideIntro once the marker lands.
            Task { [weak self] in await self?.loadEpisodeSegments() }

            // Powers the transport-bar episode picker; stays empty (picker hidden) for movies / single-episode.
            Task { [weak self] in await self?.loadSeasonEpisodes() }

        } catch is CancellationError {
            // Engine signals a SUPERSEDED load this way (newer load/stop took the singleton mid-flight,
            // rapid channel zap / dismiss during spin-up). The successor owns the engine + UI; an error
            // here would clobber it. Still release any tuner THIS load opened.
            releaseLiveTunerIfNeeded()
        } catch {
            // Release the tuner if a live load opened one before failing. No-op for VOD.
            releaseLiveTunerIfNeeded()
            if isLiveSession && !(error is APIError) {
                // Engine-level live open failure (probe fail-fast): friendly message, APIErrors keep their trio.
                setLiveChannelUnavailableError()
            } else {
                setError(from: error)
            }
            hostLoadActive = false
        }
    }

    /// Apple TV's "Match Dynamic Range" toggle; read when rendering the HDR badge so it only shows
    /// when the panel actually engages HDR.
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
    /// Whether the panel is presenting in HDR now (`UIScreen.currentEDRHeadroom` > 1.0). Feeds the
    /// engine's master-vs-media routing as the strong signal that master routing is safe even with
    /// Match Dynamic Range off (AetherEngine#4).
    static var panelIsInHDRMode: Bool {
        #if os(tvOS)
        guard let win = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first
        else { return false }
        // Headroom 1.0 = SDR, > 1.0 = HDR active; epsilon dodges a boundary float-comparison glitch.
        return win.screen.currentEDRHeadroom > 1.001
        #else
        return false
        #endif
    }

    /// PROBE (Sodalite#32, DrHurt): iOS-only experiment that lets AVKit auto-select + render a subtitle track
    /// so it survives into the PiP window, WITHOUT a host force-select (the deselect/reselect re-assert that
    /// AVSmartSubtitlesController kept disabling). The engine serves a DEFAULT=YES WebVTT rendition with eager
    /// readers; AVKit auto-selects it via its own media-selection criteria. The host skips its own preferred-
    /// subtitle apply so the inline overlay does not double up. The custom transport / chrome suppression are
    /// left intact (no native-menu interaction is needed since DEFAULT=YES auto-selects). tvOS unaffected
    /// (flag false). Not for release.
    static var nativePiPSubtitleProbe: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Tear down the session. Local work (progress reporting, KVO, engine stop) finishes inline;
    /// the network reportStop is detached so a slow Jellyfin server can't stall the dismiss path
    /// (default 30s timeout would leave the player up on a slow CDN, DrHurt #12). Session endpoints
    /// opt into a 90s timeout so the position write survives a slow origin.
    func stopPlayback() {
        // Latch teardown + cancel the in-flight launch (re-checked after every await in startPlayback;
        // cancel throws CancellationError out of player.load()) so a back-press-during-load can't resume
        // into player.load() after the player.stop() below.
        isTearingDown = true
        loadTask?.cancel()
        loadTask = nil
        stopProgressReporting()
        progressReportOnDemandTask?.cancel()
        progressReportOnDemandTask = nil
        // External dismissals (deep link / TopShelf) don't cancel the next-episode countdown; left
        // running it fires playNextEpisode() behind a dismissed player (startPlayback resets isTearingDown
        // at entry, defeating the latch). Kill every UI timer with the session.
        nextEpisodeTimer?.cancel()
        nextEpisodeTimer = nil
        controlsTimer?.cancel()
        controlsTimer = nil
        continuousSeekTask?.cancel()
        continuousSeekTask = nil
        scrubPreview.reset()
        let extractorToClose = frameExtractor
        frameExtractor = nil
        Task { await extractorToClose?.shutdown() }
        deactivateASSRendering()
        cancellables.removeAll()
        // Capture position BEFORE stopping: player.stop() resets currentTime to 0.
        let finalTicks = currentPositionTicks
        // Snapshot the payload + service and detach with a STRONG capture: a [weak self] task could be
        // deallocated by PlayerHostController's dismissal before the @MainActor hop ran, silently dropping
        // the position write.
        let svc = playbackService
        let stopReport = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: finalTicks,
            liveStreamId: activeLiveStreamID
        )
        // Engine does native teardown + HLS server shutdown + AVDisplayManager criteria reset in stopInternal().
        player.stop()
        // Tuner-release safety net: frees the server-side tuner even if the stop report fails to deliver. No-op for VOD.
        releaseLiveTunerIfNeeded()
        // Fire-and-forget so the caller can start the dismiss animation without waiting on PlaybackStopped.
        let sessionToKill = playSessionID
        Task.detached {
            do {
                try await svc.reportPlaybackStopped(stopReport)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .playbackProgressDidChange,
                        object: nil,
                        userInfo: [
                            PlaybackProgressKey.itemID: stopReport.itemId,
                            PlaybackProgressKey.positionTicks: stopReport.positionTicks
                        ]
                    )
                }
            } catch {
                #if DEBUG
                print("[SessionReport] Stop FAILED: \(error)")
                #endif
            }
            // Explicit transcode kill independent of the stop report: orphaned live transcodes write an
            // endlessly growing stream.ts and fill the server disk (DELETE /Videos/ActiveEncodings, no-op when idle).
            if let sessionToKill {
                try? await svc.stopActiveEncodings(playSessionID: sessionToKill)
            }
        }
    }

    /// Single owner of `isLoading` at runtime (AetherEngine#85): ORs the host-load flag with the engine's
    /// `playbackPhase`. `.seeking` is left to the scrub UI. The live cold-transcode first `.playing` is
    /// premature (a stall follows ~700ms later), so a would-be clear inside that window is held and a
    /// delayed recompute settles it, preserving the old debounce without the former 15s heuristic.
    private func recomputeLoadingIndicator() {
        let wantsSpinner = PlayerLoadingIndicator.showsSpinner(hostLoadActive: hostLoadActive, phase: player.playbackPhase)
        if !wantsSpinner, isLiveSession, let firstPlay = liveFirstPlayingAt,
           Date().timeIntervalSince(firstPlay) < 0.7 {
            if !scheduledLiveSpinnerRecheck {
                scheduledLiveSpinnerRecheck = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard let self else { return }
                    self.scheduledLiveSpinnerRecheck = false
                    self.recomputeLoadingIndicator()
                }
            }
            return
        }
        isLoading = wantsSpinner
    }

    // MARK: - State Observation (Combine)

    private func startObserving() {
        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .playing:
                    let firstPlay = !self.hasStartedPlaying
                    self.hasStartedPlaying = true
                    self.isPlaying = true
                    if self.isLiveSession, firstPlay {
                        // Marks the cold-transcode window; recomputeLoadingIndicator() debounces the spinner
                        // clear against it (the first .playing flips ~1s before the start segment lands, stalls,
                        // then resumes, so clearing immediately would reveal a frozen frame).
                        self.liveFirstPlayingAt = Date()
                    }
                    if self.showControls { self.scheduleControlsHide() }
                case .paused:
                    self.isPlaying = false
                case .ended:
                    // End-of-media on any backend: the engine surfaces .ended for native / software / audio
                    // alike (AetherEngine#63), so this fires uniformly without watching the AVPlayer directly.
                    self.isPlaying = false
                    // currentTime can stall a few seconds short of duration (demux's 15-20s look-ahead); cap the
                    // countdown at 10s so the overlay copy stays readable.
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
                        // Real end-of-content (movie / last episode).
                        self.onPlaybackReachedEnd?()
                    }
                case .idle:
                    // Pure teardown (stop / new load); end-of-media is .ended now, so no next-episode trigger here.
                    self.isPlaying = false
                case .loading:
                    // Spinner is driven by playbackPhase (.loading / .rebuffering / .stalled) in
                    // recomputeLoadingIndicator(); nothing state-specific to do here now (AetherEngine#85).
                    break
                case .seeking:
                    break
                case .error(let msg):
                    if self.isLiveSession, self.liveFirstPlayingAt == nil,
                       self.usedDirectLivePath, !self.didAttemptLiveFallback {
                        // Direct session died before first frame: consume the once-per-session fallback via
                        // the guarded retune path.
                        LogTap.shared.note("[LiveDirect] route=fallback reason=engine_error_pre_play(\(msg))")
                        self.handleLiveSourceReset()
                    } else if self.isLiveSession, self.liveFirstPlayingAt == nil {
                        // Live channel died before ever playing: friendly "unavailable" message ("Playback
                        // stopped" + raw text is for sessions that actually ran).
                        self.setLiveChannelUnavailableError()
                    } else if self.isLiveSession {
                        // Mid-session live error: retune (recoverable like a source reset); the retune guard
                        // surfaces a friendly error once attempts are exhausted.
                        LogTap.shared.note("[Live] route=retune reason=engine_error_mid_session(\(msg))")
                        self.handleLiveSourceReset()
                    } else {
                        self.setEnginePlaybackError(message: msg)
                    }
                }
            }
            .store(in: &cancellables)

        player.$playbackPhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeLoadingIndicator() }
            .store(in: &cancellables)

        player.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] t in self?.subtitleTime = t }
            .store(in: &cancellables)

        // Live source replay after a reconnect (Jellyfin transcode respawn re-served from the start);
        // engine parked the session and can't recover on the same URL, so re-negotiate at the live edge.
        player.liveSourceReset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleLiveSourceReset() }
            .store(in: &cancellables)

        player.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.playbackTime = time
                // Intro/outro markers are absolute source-timeline values; currentTime is the AVPlayer
                // clock (source - playlistShiftSeconds on native HLS), so compare against sourceTime.
                self.updateIntroVisibility(time: self.player.sourceTime)
                self.updateOutroAutoSkip(time: self.player.sourceTime)
                self.checkForNextEpisode()
                let dur = self.effectiveDuration
                let remaining = dur - time

                // Detect backward movement (scrub-back) and reset the next-episode overlay; > 1s tolerates
                // AVPlayer jitter. The forward-trigger below re-fires naturally on the next tick.
                let movedBackward = time + 1.0 < self.lastPlaybackTimeForNextEpisode
                self.lastPlaybackTimeForNextEpisode = time
                if movedBackward, self.showNextEpisodeOverlay {
                    self.resetNextEpisodeOverlayState()
                }

                if self.nextEpisode != nil && !self.nextEpisodeCancelled && dur > 0 && remaining > 0 {
                    // Outro available: show + fixed 10s countdown at outro.startSeconds, cutting through
                    // the credits. No outro: show at 30s remaining, countdown at 10s synced to the clock.
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
                // Time labels track the live playhead even while scrubbing (playback keeps running); the
                // scrub target previews separately in the scrub bubble (`scrubTime`).
                self.currentTime = self.formatSeconds(time)
                let rem = dur - time
                self.remainingTime = rem > 0 ? "-\(self.formatSeconds(rem))" : "-00:00"
                // Progress bar + warmed frame must NOT follow the live clock during a scrub (would fight scrubProgress).
                guard !self.isScrubbing else { return }
                // Live owns `progress` via the DVR baseline in observeLiveEdge (live duration is 0). Leave VOD untouched.
                if !self.isLiveSession {
                    self.progress = dur > 0 ? Float(time / dur) : 0
                }
                // Keep one frame warm at the playhead so the first scrub frame is on screen instantly.
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
                // Log videoFormat transitions for TestFlight diagnostics (engine sources it from the demuxer
                // probe + late-discovered HDR10+ T.35 SEI mid-stream).
                if format != self.videoFormat {
                    let line = "[PlayerVM] videoFormat changed: \(self.videoFormat) → \(format)"
                    print(line)
                    LogTap.shared.note(line)
                }
                // Only badge HDR if the panel went to HDR mode; with Match Dynamic Range off the TV stays SDR.
                #if os(tvOS)
                if format != .sdr, !Self.matchDynamicRangeEnabled {
                    self.videoFormat = .sdr
                    return
                }
                #endif
                self.videoFormat = format
            }
            .store(in: &cancellables)

        // Mirror engine cues into `subtitleCues` only when the engine is the source. The legacy HTTP path
        // (bitmap / transcode) writes subtitleCues directly with isSubtitleActive == false, so the guard
        // keeps the two paths from clobbering each other.
        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                guard self.player.isSubtitleActive else { return }
                self.subtitleCues = cues
            }
            .store(in: &cancellables)

        // Secondary companion subtitle cues (issue #47); same mirror contract as the primary sink.
        player.$secondarySubtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                guard self.player.isSecondarySubtitleActive else { return }
                self.secondarySubtitleCues = cues
            }
            .store(in: &cancellables)

        // Engine is the source of truth for the active audio track; mirror it so the picker reflects what
        // the pipeline settled on (not the requested track mid-reload, which made early scrubs look broken).
        player.$activeAudioTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                self?.activeAudioIndex = index
            }
            .store(in: &cancellables)
    }

    // MARK: - Controls

    /// True while a post-background pipeline reload is in flight. The reload auto-plays, then policy
    /// pauses ("don't auto-resume after a Home/sleep gap"); but if the user pressed Play during the
    /// slow reload that intent wins and the trailing pause must be skipped (else "play does nothing").
    private(set) var isAwaitingBackgroundReload = false
    private var userToggledDuringBackgroundReload = false

    /// Mark the start of the post-background reload window; call before awaiting `reloadAtCurrentPosition()`.
    func beginBackgroundReload() {
        isAwaitingBackgroundReload = true
        userToggledDuringBackgroundReload = false
    }

    /// Apply post-reload pause policy: hold paused on the resumed frame UNLESS the user toggled
    /// play/pause during the reload (their intent wins). Surfaces controls either way.
    func finishBackgroundReload() {
        let userIntervened = userToggledDuringBackgroundReload
        isAwaitingBackgroundReload = false
        userToggledDuringBackgroundReload = false
        if !userIntervened { player.pause() }
        showControlsTemporarily()
    }

    func togglePlayPause() {
        if isAwaitingBackgroundReload { userToggledDuringBackgroundReload = true }
        player.togglePlayPause()
        reportProgressIfNeeded()
        showControls = true
        scheduleControlsHide()
    }

    /// Seek by the user's configured interval; direction +1 (right) or -1 (left). Wraps the seconds
    /// variant so the press handler doesn't need a Preferences lookup.
    func seekJumpByConfiguredInterval(direction: Int) {
        let interval = preferences.skipIntervalSeconds
        let signed = (direction < 0 ? -1 : 1) * interval
        seekJump(seconds: Double(signed))
    }

    func seekJump(seconds: Double) {
        let dur = scrubReferenceDuration
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
        // scrubTime is VOD-only (live bar renders its own behind-live label); preview is fed for live
        // via updateLiveScrubPreview (DVR-cache thumbnails).
        if !isLiveSession {
            scrubTime = formatSeconds(Double(scrubProgress) * dur)
            scrubPreview.update(fraction: scrubProgress, durationSeconds: dur)
        } else { updateLiveScrubPreview() }

        // Auto-cancel on idle (matches scrubPanEnded): discard the scrub + fade controls after 5s if the
        // user taps left/right and walks away without committing via Select.
        controlsTimer = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            isScrubbing = false
            scrubPreview.clear()
            hideControls()
        }
    }

    /// Reset the error trio so a fresh `startPlayback` shows nothing stale while loading.
    func clearError() {
        errorMessage = nil
        errorIcon = nil
        errorTitle = nil
    }

    /// Categorise a playback-start error into an icon + title + body trio for the overlay; body stays
    /// the underlying localizedDescription so the user sees the real reason.
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

    /// Friendly trio for a live channel the server can't deliver (dead upstream); covers engine-level
    /// open failures where the raw message would be noise. Network/auth APIErrors keep setError(from:).
    func setLiveChannelUnavailableError() {
        errorIcon = "tv.slash"
        errorTitle = String(
            localized: "player.error.liveUnavailable.title",
            defaultValue: "Channel unavailable"
        )
        errorMessage = String(
            localized: "player.error.liveUnavailable.body",
            defaultValue: "The server could not open this channel's stream. The channel's source may be offline. Try again later."
        )
    }

    /// Engine-side terminal error mid-playback (decoder/renderer death, network drop after handoff);
    /// headline reads as "stopped" since playback was actually running, unlike start-up errors.
    func setEnginePlaybackError(message: String) {
        errorIcon = "exclamationmark.triangle"
        errorTitle = String(
            localized: "player.error.playback.title",
            defaultValue: "Playback stopped"
        )
        errorMessage = message
    }

    /// Apply `pictureMode` to whichever layer is on screen: writes to the engine AND fires
    /// `onPictureModeChanged` so the host mirrors the gravity onto AVKit's own AVPlayerLayer (the layer
    /// actually on screen for the native path, where without the callback the toggle is a no-op).
    func applyPictureMode() {
        switch pictureMode {
        case .original: player.videoGravity = .resizeAspect
        case .fill:     player.videoGravity = .resizeAspectFill
        }
        onPictureModeChanged?(pictureMode)
    }

    /// Fired when `applyPictureMode` resolves a new gravity; PlayerHostController hooks it to update
    /// AVPlayerViewController's own `videoGravity` (the native path's rendering).
    var onPictureModeChanged: ((PlaybackPreferences.PictureMode) -> Void)?

    /// In-player picker change; mutates session-local `pictureMode` and pushes to the engine. Not persisted.
    func selectPictureMode(_ mode: PlaybackPreferences.PictureMode) {
        pictureMode = mode
        applyPictureMode()
    }

    /// Seek to a chapter start. Index is into the sorted `chapters`; out-of-range no-ops.
    func selectChapter(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        let target = chapters[index].startSeconds
        Task { [weak self] in await self?.player.seek(to: target) }
    }

    func selectAudioTrack(id: Int) {
        // No optimistic `activeAudioIndex = id`: the $activeAudioTrackIndex sink updates the picker once
        // the engine settles, else it claims the switch happened while the pipeline is still mid-reload.
        player.selectAudioTrack(index: id)
        // Re-run auto-subtitle resolution so a manual mid-playback language switch behaves like load-time
        // (else DE → EN kept subs off even though autoSubtitleForForeignAudio would have turned them on).
        let language = player.audioTracks.first(where: { $0.id == id })?.language
        applyPreferredSubtitle(forAudioLanguage: language)
    }

    /// Dedupes subtitle streams: one EMBEDDED track per (language, codec), but descriptor variants
    /// (SDH/Forced/commentary) keep their own slot. EXTERNAL subs (sidecars, downloads) are never
    /// collapsed (each is a distinct user-curated file). Shared by initial load + post-download refetch.
    static func dedupedSubtitleStreams(from mediaStreams: [MediaStream]?) -> [MediaStream] {
        let allSubStreams = mediaStreams?.filter { $0.type == .subtitle } ?? []
        var seen = Set<String>()
        return allSubStreams.filter { stream in
            if stream.isExternal == true { return true }
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
    }

    /// Resolves which subtitle to surface for the active audio language:
    /// 1. Explicit `preferredSubtitleLanguage` always wins.
    /// 2. Else if `autoSubtitleForForeignAudio` and audio isn't the preferred language, surface subs
    ///    in the preferred audio language (the "Netflix convention").
    /// 3. No match → leave the current selection alone (may be a manual user pick).
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

    /// PROBE (Sodalite#32): the native legible ordinal currently selected, remembered so the selection can be
    /// re-asserted after a background/foreground rebuild or a PiP->fullscreen restore (AVKit drops it).
    private var probeNativeOrdinal: Int?

    /// Re-assert the native legible selection (e.g. on foreground after AVKit reconciled it away). No-op off the probe.
    func reassertNativeSubtitleProbe(reason: String) {
        guard Self.nativePiPSubtitleProbe, let ord = probeNativeOrdinal else { return }
        LogTap.shared.note("[PiPDiag] host: re-assert(\(reason)) setNativeSubtitleSelected(\(ord)) currentItem=\(player.currentAVPlayer?.currentItem != nil)")
        player.setNativeSubtitleSelected(track: ord)
    }

    /// PROBE (Sodalite#32): stop AVKit from auto-selecting a persisted subtitle at load. Its legible renderer
    /// won't attach for a selection made before the view is established (device: nothing renders until a seek,
    /// which is a disruptive producer restart over our loopback), and a programmatic re-assert does not attach it
    /// either. Starting subs OFF and letting the user pick during playback (which DOES attach) is the reliable,
    /// non-disruptive path. Deselect + criteria-off so AVKit doesn't immediately re-auto-select.
    func disablePersistedLegibleAtLoad() async {
        guard Self.nativePiPSubtitleProbe,
              let av = player.currentAVPlayer, let item = av.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
        av.appliesMediaSelectionCriteriaAutomatically = false
        let had = item.currentMediaSelection.selectedMediaOption(in: group) != nil
        item.select(nil, in: group)
        LogTap.shared.note("[PiPDiag] host: cleared auto-selected legible at load (hadSelection=\(had)); user picks during playback")
    }

    /// Picks the most useful subtitle in a language for following dialog: full > SDH/CC > forced;
    /// signs/songs/commentary excluded. `min(by:)` is stable so ties keep source order.
    private func bestSubtitleMatch(forLanguage language: String) -> MediaStream? {
        let candidates = subtitleStreams.filter {
            Self.languagesMatch($0.language, language)
        }
        guard !candidates.isEmpty else { return nil }
        return candidates.min(by: {
            Self.subtitleAutoPickRank($0) < Self.subtitleAutoPickRank($1)
        })
    }

    /// Lower rank wins (see `bestSubtitleMatch`). `descriptorRank * 2 + bitmapPenalty` keeps the
    /// descriptor axis (full > SDH > forced > signs/songs) dominant, codec (text < bitmap) a tiebreaker:
    /// full bitmap beats forced text (coverage > styling), full text beats full bitmap (user styling
    /// only applies to text cues).
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

    /// Effective preferred audio language for foreign-audio detection. Settings' "Auto" stores nil; we
    /// substitute the device's primary language code so "Auto" still gives auto-subs (else the guard
    /// has nothing to compare against).
    // Not private: the +Live extension (separate file) reads it to seed LoadOptions.preferredAudioLanguages.
    func effectivePreferredAudioLanguage() -> String? {
        if let explicit = preferences.preferredAudioLanguage {
            return explicit
        }
        return Locale.current.language.languageCode?.identifier
    }

    /// Loose language-tag comparison so settings ("ger"), container metadata ("deu"), and BCP-47 ("de")
    /// line up; without it auto-subtitles silently failed when codes differed in format.
    static func languagesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased() else { return false }
        if a == b { return true }
        return languageSynonyms.contains { $0.contains(a) && $0.contains(b) }
    }

    /// ISO 639-1 / 639-2/T / 639-2/B equivalence classes; anything outside falls back to strict equality.
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

    /// Toggles `isInsideIntro` from the playback-time sink so the UI shows/hides Skip Intro.
    func updateIntroVisibility(time: Double) {
        guard let seg = introSegment else {
            if isInsideIntro { setInsideIntro(false) }
            didSkipCurrentIntro = false
            return
        }

        // Skip-lockout: keep the pill hidden after a skip; clears only when the playhead moves below
        // intro start. Without it, stale pre-seek ticks revive the pill for a frame after the tap.
        if didSkipCurrentIntro {
            if time < seg.startSeconds {
                didSkipCurrentIntro = false
            } else {
                if isInsideIntro { setInsideIntro(false) }
                return
            }
        }

        // Plugin sometimes reports introStart=0 on cold-opens; the 0.5s floor stops the pill popping
        // before titles play.
        let inside = time >= max(seg.startSeconds, 0.5)
                  && time < seg.endSeconds - 1   // hide 1s before end

        // Auto-skip on the first tick inside the intro (opt-in), guarded to fire once per episode.
        if inside && preferences.autoSkipIntro && !didAutoSkipCurrentIntro {
            didAutoSkipCurrentIntro = true
            skipIntro()
            return
        }

        if inside != isInsideIntro {
            setInsideIntro(inside)
        }
    }

    /// Update the flag and move focus off the Skip Intro button if it just vanished, else the user is stuck on it.
    private func setInsideIntro(_ newValue: Bool) {
        isInsideIntro = newValue
        if !newValue && controlsFocus == .skipIntroButton {
            if !player.audioTracks.isEmpty { controlsFocus = .audioButton }
            else if !subtitleStreams.isEmpty { controlsFocus = .subtitleButton }
            else { controlsFocus = .speedButton }
        }
    }

    /// Jump past the intro. Triggered by the Skip Intro button.
    func skipIntro() {
        guard let seg = introSegment else { return }
        isInsideIntro = false
        didSkipCurrentIntro = true
        Task { [weak self] in
            // seg.endSeconds is absolute source time; seek(to:) is source-PTS based and applies the clock shift itself.
            await self?.player.seek(to: seg.endSeconds)
            // Clear the lockout after a 500ms settle (absorbs post-seek jitter) so a deliberate
            // backward scrub re-offers the pill; without it the lockout persists the whole episode.
            try? await Task.sleep(for: .milliseconds(500))
            self?.didSkipCurrentIntro = false
        }
    }

    /// Outro auto-skip (no Skip Outro button), fires once per episode at the outro boundary:
    /// - autoSkipOutro + autoplayNextEpisode + next ready → jump straight to the next episode.
    /// - else → seek to outro.endSeconds and let the regular next-episode flow take over.
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

    /// Fetch intro + outro markers once on startup. Safe if the server lacks the endpoint (empty struct,
    /// features stay off).
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
        // Cancel any in-flight transcode-path load so a slow earlier extraction can't overwrite the
        // cues for the track the user just selected (or disabled).
        subtitleLoadTask?.cancel()
        subtitleLoadTask = nil
        guard let id else {
            activeSubtitleIndex = nil
            activeSubtitleCodec = nil
            subtitleCues = []
            deactivateASSRendering()
            player.clearSubtitle()
            return
        }
        activeSubtitleIndex = id
        // Drop the secondary if it equals the new primary (a track can't be both lines).
        if activeSecondarySubtitleIndex == id {
            selectSecondarySubtitleTrack(id: nil)
        }
        let stream = subtitleStreams.first(where: { $0.index == id })
        activeSubtitleCodec = stream?.codec?.lowercased()
        let isExternal = stream?.isExternal == true

        if isExternal {
            deactivateASSRendering()
            // Sidecar file: hand the URL to the engine (FFmpeg decode, no host SRTParser); cues land on
            // engine.subtitleCues and the mirror sink picks them up.
            if let url = playbackService.buildSubtitleURL(
                itemID: item.id,
                mediaSourceID: mediaSourceID,
                streamIndex: id,
                format: stream?.codec ?? "srt"
            ) {
                player.selectSidecarSubtitle(url: url)
                subtitleCues = []
                // Styled ASS for external .ass/.ssa: wait for the async engine.sidecarASSHeader, then
                // activate the coordinator like the embedded path (AetherEngine#48).
                if (activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"),
                   preferences.styledASSSubtitles {
                    activateSidecarASSWhenHeaderArrives()
                }
            } else {
                player.clearSubtitle()
                subtitleCues = []
            }
        } else if activePlayMethod != .transcode {
            // Embedded stream on direct play/stream: engine streams cues from the main demux loop (text
            // and bitmap codecs alike), no second connection or server extraction.
            player.selectSubtitleTrack(index: id)
            subtitleCues = player.subtitleCues
            // ASS/SSA gets the styled libass path on top (coordinator reassembles raw event cues for
            // swift-ass-renderer); falls back to the stripped-text overlay when the header is missing.
            if (activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"),
               preferences.styledASSSubtitles {
                let engineTrack = player.subtitleTracks.first(where: { $0.id == id })
                // Renderer can arrive async when embedded font attachments need writing; the callback
                // mirrors it then, the direct read below covers the synchronous warm path.
                assCoordinator.onRendererChanged = { [weak self] renderer in
                    self?.assRenderer = renderer
                }
                assCoordinator.activate(header: engineTrack?.assHeader, itemID: item.id)
                assRenderer = assCoordinator.renderer
            } else {
                deactivateASSRendering()
            }
        } else {
            // Transcoded session: HLS rewrites stream indices, so fall back to the legacy server-extracted
            // SRT loader (text codecs only).
            deactivateASSRendering()
            player.clearSubtitle()
            subtitleCues = []
            subtitleLoadTask = Task { await loadSubtitles(streamIndex: id) }
        }
    }

    /// Select the SECONDARY companion subtitle track (issue #47). Text-only, session-only: no styled-ASS,
    /// no transcode fallback (only direct play / sidecar offer a secondary), no persistence.
    func selectSecondarySubtitleTrack(id: Int?) {
        guard let id else {
            activeSecondarySubtitleIndex = nil
            secondarySubtitleCues = []
            player.clearSecondarySubtitle()
            return
        }
        activeSecondarySubtitleIndex = id
        let stream = subtitleStreams.first(where: { $0.index == id })
        let isExternal = stream?.isExternal == true

        if isExternal {
            if let url = playbackService.buildSubtitleURL(
                itemID: item.id,
                mediaSourceID: mediaSourceID,
                streamIndex: id,
                format: stream?.codec ?? "srt"
            ) {
                player.selectSecondarySidecarSubtitle(url: url)
                secondarySubtitleCues = []
            } else {
                player.clearSecondarySubtitle()
                secondarySubtitleCues = []
                activeSecondarySubtitleIndex = nil
            }
        } else if activePlayMethod != .transcode {
            player.selectSecondarySubtitleTrack(index: id)
            secondarySubtitleCues = player.secondarySubtitleCues
        } else {
            // Transcoded session: no secondary path in v1.
            player.clearSecondarySubtitle()
            secondarySubtitleCues = []
            activeSecondarySubtitleIndex = nil
        }
    }

    /// Activate styled ASS for an external sidecar once the engine publishes its (async) header:
    /// subscribe to `engine.$sidecarASSHeader` and activate on the first non-nil value (AetherEngine#48).
    /// No header → coordinator never activates and the overlay's stripper handles the raw lines.
    private func activateSidecarASSWhenHeaderArrives() {
        sidecarASSHeaderCancellable?.cancel()
        assCoordinator.onRendererChanged = { [weak self] renderer in
            self?.assRenderer = renderer
        }
        sidecarASSHeaderCancellable = player.$sidecarASSHeader
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .first()
            .sink { [weak self] header in
                guard let self else { return }
                self.assCoordinator.activate(header: header, itemID: self.item.id)
                self.assRenderer = self.assCoordinator.renderer
            }
    }

    /// Tear down the styled ASS bridge and clear its observable mirror; safe when already inactive.
    /// Internal so the cross-file NextEpisode extension can call it on bypass-teardown transitions.
    func deactivateASSRendering() {
        sidecarASSHeaderCancellable?.cancel()
        sidecarASSHeaderCancellable = nil
        assCoordinator.deactivate()
        assRenderer = nil
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

        // First hit can take seconds (Jellyfin lazy-extracts the sub via FFmpeg, nothing cached yet).
        // Two attempts with a 120s budget cover both the slow extraction and a transient.
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
                // A slow extraction may finish after the user switched/disabled the track; only the
                // still-selected stream may write, so a stale load is a no-op.
                guard !Task.isCancelled, activeSubtitleIndex == streamIndex else {
                    Self.subtitleLog.notice("→ stale load for \(streamIndex, privacy: .public) dropped (active=\(self.activeSubtitleIndex ?? -1, privacy: .public))")
                    return
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

    #if os(iOS)
    enum PlayerHUDKind: Equatable { case brightness, volume, skipForward, skipBackward }

    /// Transient touch HUD (brightness/volume swipe, skip ripple); the overlay observes hudKind.
    var hudKind: PlayerHUDKind?
    var hudLevel: Double = 0
    @ObservationIgnored private var hudHideTask: Task<Void, Never>?

    func flashHUD(_ kind: PlayerHUDKind, level: Double = 0) {
        hudKind = kind
        hudLevel = level
        hudHideTask?.cancel()
        hudHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.hudKind = nil
        }
    }

    /// Touch skip (double-tap sides). seekJump sets the scrub target (the tvOS model then waits for a
    /// Select press to commit); on touch we commit immediately so it actually seeks.
    func skip(by seconds: Double) {
        seekJump(seconds: seconds)
        commitScrub()
        flashHUD(seconds >= 0 ? .skipForward : .skipBackward)
    }

    func setBrightness(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.screen.brightness = clamped
        flashHUD(.brightness, level: Double(clamped))
    }

    func setVolume(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        PlayerSystemVolume.set(clamped)
        flashHUD(.volume, level: Double(clamped))
    }

    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    /// Suppresses the activation-time KVO callback so opening a video does not flash the HUD.
    @ObservationIgnored private var volumeHUDArmed = false

    /// Mirror the system volume overlay with our own HUD on hardware volume-button presses. The hidden
    /// MPVolumeView the swipe gesture uses suppresses the native iOS overlay, so it never shows otherwise.
    func startVolumeObservation() {
        volumeObservation?.invalidate()
        volumeHUDArmed = false
        // @Sendable so the KVO callback is nonisolated (KVO fires off the main actor); it hops back via Task.
        let handler: @Sendable (AVAudioSession, NSKeyValueObservedChange<Float>) -> Void = { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                guard let self, self.volumeHUDArmed else { return }
                self.flashHUD(.volume, level: Double(newValue))
            }
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new], changeHandler: handler)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.volumeHUDArmed = true
        }
    }

    func stopVolumeObservation() {
        volumeObservation?.invalidate()
        volumeObservation = nil
        volumeHUDArmed = false
    }
    #endif

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

    /// Pause the controls auto-hide while the user is actively in a touch menu; re-arm via scheduleControlsHide().
    func cancelControlsHide() {
        controlsTimer?.cancel()
    }

    // MARK: - Transport control activation (shared by the tvOS press dispatch and iOS taps)

    /// Runs the action for a focused/tapped transport control. tvOS calls this from selectPressed;
    /// iOS calls it directly from the SwiftUI track buttons.
    func activateControl(_ focus: ControlsFocus) {
        switch focus {
        case .skipIntroButton: skipIntro()
        case .chapterButton: openChapterDropdown()
        case .episodeButton: openEpisodeDropdown()
        case .audioButton: openAudioDropdown()
        case .subtitleButton: openSubtitleDropdown()
        case .speedButton: openSpeedDropdown()
        case .pictureButton: openPictureDropdown()
        case .infoButton:
            showStatsOverlay.toggle()
            scheduleControlsHide()
        case .returnToLiveButton:
            returnToLiveEdge()
            controlsFocus = .progressBar
            scheduleControlsHide()
        default:
            break
        }
    }

    func openAudioDropdown() {
        let tracks = displayAudioTracks
        guard !tracks.isEmpty else { return }
        controlsTimer?.cancel()
        let currentIdx = tracks.firstIndex(where: { $0.id == activeAudioIndex }) ?? 0
        trackDropdown = .audio(highlighted: currentIdx)
    }

    func openSubtitleDropdown() {
        controlsTimer?.cancel()
        let currentIdx: Int
        if let activeId = activeSubtitleIndex,
           let streamIdx = displaySubtitleStreams.firstIndex(where: { $0.index == activeId }) {
            currentIdx = streamIdx + 1
        } else {
            currentIdx = 0
        }
        trackDropdown = .subtitle(highlighted: currentIdx)
    }

    func openSpeedDropdown() {
        controlsTimer?.cancel()
        trackDropdown = .speed(highlighted: activeSpeedIndex)
    }

    func openPictureDropdown() {
        controlsTimer?.cancel()
        let modes = PlaybackPreferences.PictureMode.allCases
        let currentIdx = modes.firstIndex(of: pictureMode) ?? 0
        trackDropdown = .picture(highlighted: currentIdx)
    }

    func openEpisodeDropdown() {
        guard seasonEpisodes.count > 1 else { return }
        controlsTimer?.cancel()
        let currentIdx = seasonEpisodes.firstIndex(where: { $0.id == item.id }) ?? 0
        trackDropdown = .episode(highlighted: currentIdx)
    }

    func openChapterDropdown() {
        guard chapters.count > 1 else { return }
        controlsTimer?.cancel()
        // sourceTime, not currentTime: chapter marks are on the absolute source timeline.
        let nowSeconds = player.sourceTime
        var currentIdx = 0
        for (i, chapter) in chapters.enumerated() {
            if chapter.startSeconds <= nowSeconds + 0.001 { currentIdx = i } else { break }
        }
        trackDropdown = .chapter(highlighted: currentIdx)
    }

    func confirmDropdownSelection() {
        switch trackDropdown {
        case .chapter(let idx):
            selectChapter(at: idx)
            trackDropdown = .none
            scheduleControlsHide()
        case .episode(let idx):
            trackDropdown = .none
            Task { await selectEpisode(at: idx) }
        case .audio(let idx):
            let tracks = displayAudioTracks
            if idx < tracks.count { selectAudioTrack(id: tracks[idx].id) }
            trackDropdown = .none
            scheduleControlsHide()
        case .subtitle(let idx):
            let streams = displaySubtitleStreams
            if idx == 0 {
                trackDropdown = .secondarySubtitle(highlighted: 0)
            } else if idx == 1 {
                selectSubtitleTrack(id: nil)
                trackDropdown = .none
                scheduleControlsHide()
            } else if idx == streams.count + 2 {
                trackDropdown = .none
                presentSubtitleSearch()
            } else {
                let streamIdx = idx - 2
                if streamIdx < streams.count { selectSubtitleTrack(id: streams[streamIdx].index) }
                trackDropdown = .none
                scheduleControlsHide()
            }
        case .secondarySubtitle(let idx):
            let candidates = secondarySubtitleCandidates
            if idx == 0 {
                trackDropdown = .subtitle(highlighted: 0)
            } else if idx == 1 {
                selectSecondarySubtitleTrack(id: nil)
                trackDropdown = .none
                scheduleControlsHide()
            } else {
                let candidateIdx = idx - 2
                if candidateIdx < candidates.count { selectSecondarySubtitleTrack(id: candidates[candidateIdx].index) }
                trackDropdown = .none
                scheduleControlsHide()
            }
        case .speed(let idx):
            selectSpeed(index: idx)
            trackDropdown = .none
            scheduleControlsHide()
        case .picture(let idx):
            let modes = PlaybackPreferences.PictureMode.allCases
            if modes.indices.contains(idx) { selectPictureMode(modes[idx]) }
            trackDropdown = .none
            scheduleControlsHide()
        case .none:
            break
        }
    }

    /// iOS: a tapped dropdown row re-points the open dropdown's highlight, then confirms.
    func selectDropdownItem(at index: Int) {
        switch trackDropdown {
        case .audio: trackDropdown = .audio(highlighted: index)
        case .subtitle: trackDropdown = .subtitle(highlighted: index)
        case .secondarySubtitle: trackDropdown = .secondarySubtitle(highlighted: index)
        case .speed: trackDropdown = .speed(highlighted: index)
        case .picture: trackDropdown = .picture(highlighted: index)
        case .episode: trackDropdown = .episode(highlighted: index)
        case .chapter: trackDropdown = .chapter(highlighted: index)
        case .none: return
        }
        confirmDropdownSelection()
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
