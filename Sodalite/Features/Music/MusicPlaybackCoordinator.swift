import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit
import AetherEngine

/// Owns music playback end-to-end: the play queue, transport controls,
/// driving the shared `AetherEngine` audio-only backend, the audio
/// session, Jellyfin session reporting, and the music -> video handoff
/// teardown.
///
/// Mirrors `PlayerViewModel`'s patterns: `@MainActor @Observable`, Combine
/// sinks observing the engine's `@Published` properties stored in a
/// `Set<AnyCancellable>`, and fire-and-forget Jellyfin reports.
///
/// The engine (`DependencyContainer.playerEngine`) is a process-wide
/// singleton shared with the video player. When a video load happens on
/// the engine while a music queue is live, the engine's own `stopInternal`
/// tears down the audio host; this coordinator watches `playbackBackend`
/// leaving `.audio` and clears its own state without re-stopping the
/// engine (it has already moved on).
///
/// System Now-Playing (the tvOS Home overlay + Control Center + Siri
/// Remote) is driven by the `+NowPlaying` extension via a per-player
/// `MPNowPlayingSession`. `updateNowPlaying()` / `clearNowPlaying()` are
/// called at every track-change / play-pause / seek transition.
@MainActor
@Observable
final class MusicPlaybackCoordinator {
    // `engine` and `imageService` are accessed by the +NowPlaying
    // extension (separate file, same module), so they cannot be `private`.
    let engine: AetherEngine
    private let playbackService: JellyfinPlaybackServiceProtocol
    let imageService: JellyfinImageService
    private let userIDProvider: () -> String?

    private(set) var queue: [JellyfinItem] = []
    private(set) var currentIndex: Int = 0
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    /// Bumped whenever the fullscreen Now-Playing screen should be presented
    /// (a track tap, the Now-Playing card tap). AppRouter watches this and
    /// drives the `fullScreenCover`, since the cover state lives there.
    private(set) var nowPlayingPresentationRequest: Int = 0

    // MARK: - Scrubbing (see +Scrubbing)

    /// True while the user is scrubbing the fullscreen player's progress bar
    /// (touchpad pan, left/right skip, or a held spool). The bar shows
    /// `scrubProgress` instead of the live position while this is set.
    var isScrubbing = false
    /// The previewed scrub position as a 0...1 fraction of the duration.
    var scrubProgress: Double = 0
    /// The in-flight continuous (hold-to-seek) spool task; non-nil while a
    /// left/right press is held.
    var continuousSeekTask: Task<Void, Never>?

    var currentItem: JellyfinItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }
    var hasNext: Bool { currentIndex + 1 < queue.count }
    var hasPrevious: Bool { currentIndex > 0 }

    // MARK: - Session reporting bookkeeping

    private var playSessionId: String?
    private var currentMediaSourceId: String?
    private var lastProgressReport: Date = .distantPast
    /// Distinguishes a user-driven stop (or a music->video handoff) from a
    /// track reaching its natural end. Latched true before any teardown so
    /// the `$state == .idle` sink does not mistake the engine's stop for an
    /// end-of-track and recursively advance / re-stop.
    private var isStopping: Bool = false
    /// True only while the audio session has been configured + activated.
    /// Keeps `loadAndPlayCurrent` from re-touching `AVAudioSession` on every
    /// track within a queue.
    private var didConfigureAudioSession: Bool = false
    private var cancellables = Set<AnyCancellable>()

    /// Now-Playing bookkeeping (see +NowPlaying). `didRegisterRemoteCommands`
    /// gates one-time MPRemoteCommandCenter target registration;
    /// `nowPlayingArtworkItemID` is the item id captured when an async
    /// artwork load starts, compared on completion to drop stale artwork.
    var didRegisterRemoteCommands = false
    var nowPlayingArtworkItemID: String?
    /// The resolved artwork for the current track, cached so a state /
    /// duration now-playing refresh keeps showing it instead of flashing
    /// empty while a fresh load runs. Cleared on stop / track change.
    var cachedArtwork: MPMediaItemArtwork?
    var cachedArtworkItemID: String?

    /// Minimum spacing between fire-and-forget progress reports.
    private static let progressReportInterval: TimeInterval = 10

    init(engine: AetherEngine,
         playbackService: JellyfinPlaybackServiceProtocol,
         imageService: JellyfinImageService,
         userIDProvider: @escaping () -> String?) {
        self.engine = engine
        self.playbackService = playbackService
        self.imageService = imageService
        self.userIDProvider = userIDProvider
        subscribeToEngine()
    }

    /// The album / playlist this queue was started from, shown as the title
    /// in the fullscreen player (the per-track title lives in the queue).
    private(set) var contextTitle: String?

    // MARK: - Public transport

    /// Replace the queue and start playing at `index`. Index is clamped
    /// into the queue bounds so callers can pass a raw tap position safely.
    /// `contextTitle` is the album/playlist name shown in the player. Also
    /// requests the fullscreen Now-Playing screen: starting playback (track
    /// tap, album play/shuffle) surfaces the player.
    func play(queue items: [JellyfinItem], startAt index: Int, contextTitle: String? = nil) {
        self.contextTitle = contextTitle
        queue = items
        currentIndex = items.isEmpty ? 0 : max(0, min(index, items.count - 1))
        requestNowPlayingPresentation()
        Task { await loadAndPlayCurrent() }
    }

    /// Jump to another track in the CURRENT queue (used by the player's queue
    /// list), keeping the queue + context title intact.
    func skip(toQueueIndex index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        Task { await loadAndPlayCurrent() }
    }

    /// Ask AppRouter to present the fullscreen Now-Playing screen (used by
    /// the Now-Playing card, which resumes an existing session rather than
    /// starting a new one).
    func requestNowPlayingPresentation() {
        nowPlayingPresentationRequest += 1
    }

    func togglePlayPause() {
        // Reactivate the audio session before a resume (see resume()).
        if !isPlaying { configureAudioSessionIfNeeded() }
        engine.togglePlayPause()
        // isPlaying is derived from the engine state sink; the sink also
        // refreshes now-playing on the play/pause transition.
    }

    /// Resume playback. Reactivates the audio session first because the
    /// system may have deactivated it when playback paused, after which
    /// AVPlayer.play() yields no audio. Used by the remote/CC play command.
    func resume() {
        configureAudioSessionIfNeeded()
        engine.play()
    }

    /// Advance to the next track, or stop if the queue is exhausted.
    func next() {
        if hasNext {
            currentIndex += 1
            Task { await loadAndPlayCurrent() }
        } else {
            stop()
        }
    }

    /// Standard music "previous" behavior: if we're more than 3 s into the
    /// track (or there's nothing before it), restart the current track;
    /// otherwise step back one track.
    func previous() {
        if currentTime > 3 || !hasPrevious {
            Task { await loadAndPlayCurrent() }
        } else {
            currentIndex -= 1
            Task { await loadAndPlayCurrent() }
        }
    }

    func seek(to seconds: Double) {
        Task { await engine.seek(to: seconds) }
        updateNowPlaying()
    }

    /// User-driven stop. Latches `isStopping` first so the engine's
    /// transition to `.idle` (and then `.none` backend) is not mistaken
    /// for a natural track end / handoff and does not recursively fire.
    func stop() {
        isStopping = true
        reportStopped()
        engine.stop()
        queue = []
        currentIndex = 0
        isPlaying = false
        currentTime = 0
        duration = 0
        playSessionId = nil
        currentMediaSourceId = nil
        didConfigureAudioSession = false
        clearNowPlaying()
        isStopping = false
    }

    // MARK: - Load + play

    private func loadAndPlayCurrent() async {
        guard let item = currentItem, let userID = userIDProvider() else { return }

        configureAudioSessionIfNeeded()

        do {
            let info = try await playbackService.getPlaybackInfo(
                itemID: item.id,
                userID: userID,
                profile: nil
            )
            guard let source = info.mediaSources.first else {
                LogTap.shared.note("[MusicCoordinator] no media source for \(item.name)")
                return
            }
            currentMediaSourceId = source.id
            playSessionId = info.playSessionId

            guard let url = playbackService.buildAudioStreamURL(
                itemID: item.id,
                mediaSourceID: source.id,
                container: source.container,
                isStatic: true
            ) else {
                LogTap.shared.note("[MusicCoordinator] could not build audio URL for \(item.name)")
                return
            }

            // Clear the stopping latch on a fresh successful load so the
            // end-of-track and handoff sinks arm for this new track. Set
            // here (not earlier) so a load failure leaves the latch as-is.
            isStopping = false

            try await engine.load(
                url: url,
                startPosition: nil,
                options: LoadOptions(audioOnly: true)
            )

            // Publish now-playing + register the shared remote commands
            // BEFORE the first play(). tvOS only registers the app as the
            // system Now-Playing source, and flips the Siri Remote button to
            // a play affordance, when the info center is populated and the
            // handlers are bound ahead of playback starting (WWDC17 S251).
            updateNowPlaying()
            engine.play()

            reportStart()
        } catch {
            LogTap.shared.note("[MusicCoordinator] load failed for \(item.name): \(error)")
            // Leave state sane: do not advance, do not flip isPlaying true.
            isPlaying = false
        }
    }

    /// Ensure the audio session is active. Called before every load and
    /// resume, NOT gated by a one-time flag: the system can deactivate the
    /// session when playback pauses, after which AVPlayer.play() produces
    /// no audio until the session is reactivated. setCategory/setActive are
    /// idempotent, so calling this repeatedly is cheap.
    private func configureAudioSessionIfNeeded() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            didConfigureAudioSession = true
            LogTap.shared.note("[MusicCoordinator] audio session active, category=\(session.category.rawValue)")
        } catch {
            LogTap.shared.note("[MusicCoordinator] audio session setup FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Engine observation

    private func subscribeToEngine() {
        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                guard let self else { return }
                self.currentTime = time
                // Throttle progress reports to at most one per interval.
                let now = Date()
                if now.timeIntervalSince(self.lastProgressReport) >= Self.progressReportInterval {
                    self.lastProgressReport = now
                    self.reportProgress()
                }
            }
            .store(in: &cancellables)

        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dur in
                guard let self else { return }
                guard dur > 0, dur != self.duration else { return }
                self.duration = dur
                // The AVPlayer path publishes duration asynchronously after
                // the item is ready, so the now-playing info set at track
                // load had duration 0. Refresh it so the system UI shows the
                // correct length and progress.
                self.updateNowPlaying()
            }
            .store(in: &cancellables)

        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let wasPlaying = self.isPlaying
                self.isPlaying = (state == .playing)
                // Refresh now-playing on a play/pause transition so the
                // native rate / elapsed reflect reality.
                if self.isPlaying != wasPlaying {
                    self.updateNowPlaying()
                }

                // Natural end-of-track detection. The engine reaches
                // `.idle` when the source runs out. Only treat it as an
                // end-of-track when we did NOT initiate the stop ourselves
                // and a queue is still live; otherwise this is our own
                // stop()/handoff teardown and must not recurse.
                if state == .idle, !self.isStopping, !self.queue.isEmpty {
                    if self.hasNext {
                        self.next()
                    } else {
                        self.stop()
                    }
                }
            }
            .store(in: &cancellables)

        engine.$playbackBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] backend in
                guard let self else { return }
                // Music -> video handoff: a video load on the shared engine
                // flips the backend to `.native` or `.software`. The engine
                // has already torn the audio host down via its own
                // stopInternal, so we clear OUR state without calling
                // engine.stop() (that would stop the video that just took
                // over). Gate on the concrete video backends so the normal
                // `.audio -> .none` transition our own stop() produces does
                // not re-enter here.
                guard backend == .native || backend == .software else { return }
                guard !self.queue.isEmpty else { return }
                self.isStopping = true
                self.reportStopped()
                self.queue = []
                self.currentIndex = 0
                self.isPlaying = false
                self.currentTime = 0
                self.duration = 0
                self.playSessionId = nil
                self.currentMediaSourceId = nil
                self.didConfigureAudioSession = false
                self.clearNowPlaying()
                self.isStopping = false
            }
            .store(in: &cancellables)

        // Re-publish now-playing on app foreground/background transitions.
        // tvOS sources the Home top-right Now-Playing badge from a now-playing
        // update that lands around the background transition; if the last
        // write happened while still foreground (which is the case for music
        // that started playing before minimizing) the badge never appears.
        // Re-publishing here, with the current live state, gives the system a
        // fresh entry to display the moment the app backgrounds.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentItem != nil else { return }
                self.updateNowPlaying()
            }
            .store(in: &cancellables)

        // Keep the system now-playing entry continuously fresh while a track
        // is loaded (playing OR paused). tvOS renders the Home Now-Playing
        // overlay from a recent entry and drops a stale one, so without this
        // the badge lags ~2s behind our last discrete write and a pause lets
        // the overlay (and the remote play route) disappear. A light 2s
        // elapsed/rate refresh keeps us live and moves the system scrubber.
        Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, self.currentItem != nil else { return }
                self.refreshNowPlayingElapsed()
            }
            .store(in: &cancellables)
    }

    // MARK: - Jellyfin session reporting

    private var positionTicks: Int64 { Int64(currentTime * 10_000_000) }

    private func reportStart() {
        guard let item = currentItem, let mediaSourceId = currentMediaSourceId else { return }
        let report = PlaybackStartReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
            canSeek: true,
            playMethod: PlayMethod.directPlay.rawValue,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        let svc = playbackService
        Task { try? await svc.reportPlaybackStart(report) }
    }

    private func reportProgress() {
        guard let item = currentItem, let mediaSourceId = currentMediaSourceId else { return }
        let ticks = positionTicks
        guard ticks > 0 else { return }
        let report = PlaybackProgressReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: ticks,
            isPaused: !isPlaying,
            canSeek: true,
            playMethod: PlayMethod.directPlay.rawValue,
            audioStreamIndex: nil,
            subtitleStreamIndex: nil
        )
        let svc = playbackService
        Task { try? await svc.reportPlaybackProgress(report) }
    }

    private func reportStopped() {
        guard let item = currentItem, let mediaSourceId = currentMediaSourceId else { return }
        let report = PlaybackStopReport(
            itemId: item.id,
            mediaSourceId: mediaSourceId,
            playSessionId: playSessionId,
            positionTicks: positionTicks,
            liveStreamId: nil
        )
        let svc = playbackService
        Task { try? await svc.reportPlaybackStopped(report) }
    }

    // MARK: - Now Playing hooks (implemented in +NowPlaying)

    private func updateNowPlaying() { applyNowPlayingInfo() }
    private func clearNowPlaying() { clearNowPlayingInfo() }
}
