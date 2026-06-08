import SwiftUI
import AetherEngine
import AVFoundation
import AVKit
import Combine

// MARK: - Player View Controller

/// Full-screen video player that handles ALL Siri Remote input.
///
/// Subclasses `AVPlayerViewController` with `showsPlaybackControls
/// = true` (required on tvOS to activate AVKit's internal Now Playing
/// session auto-publish, AirPods auto-detection, Enhance Dialogue,
/// Reduce Loud Sounds, synchronized Atmos). Visible chrome is
/// suppressed, EXCEPT the transport bar, which stays enabled:
///   - `playbackControlsIncludeTransportBar = true` (kept ON so AVKit
///     routes iPhone Control Center skip events into our delegate; its
///     visible bar is covered by the SwiftUI overlay). This also leaves
///     AVKit's internal play/pause handler active, so the engine
///     reconciles its `state` from the live player rather than trusting
///     its own play()/pause() calls (AetherEngine `togglePlayPause` +
///     `timeControlStatus` sync), otherwise rapid presses get swallowed.
///   - `playbackControlsIncludeInfoViews = false`
///   - `contextualActions = []`
///
/// AVKit's backend stays active for the privileged code paths; only
/// the visible UI is suppressed. Apple-supported configuration on
/// tvOS 11+ (DisableTransportBarDemo sample demonstrates the same
/// approach). System Now Playing surfaces via AVKit's internal
/// session reading `AVPlayerItem.externalMetadata`; the engine
/// stages title / description before each load and refreshes with
/// artwork post-load.
///
/// Earlier iterations failed because:
///   - `showsPlaybackControls = false` disabled AVKit's auto-session
///     entirely (verified empty CC at c22b295)
///   - An explicit `MPNowPlayingSession(players:)` conflicted with
///     AVKit's internal session (verified CoreMediaErrorDomain -16046
///     at d30bace).
///   - Manual `MPNowPlayingInfoCenter.nowPlayingInfo` writes tripped
///     `_dispatch_assert_queue_fail` deep inside MediaPlayer
///     regardless of timing.
///
/// Presented via UIKit `present(_:animated:)`, NOT SwiftUI
/// fullScreenCover. UIKit modals allow our Menu tap recognizer to
/// fire; SwiftUI fullScreenCover would steal Menu at the
/// presentation level.
@MainActor
final class PlayerHostController: AVPlayerViewController {
    /// `internal` (not `private`) so cross-file extensions like
    /// PlayerHostController+SkipDelegate can route AVKit delegate
    /// callbacks back into the view model. Every other property
    /// stays `private` to this file.
    let viewModel: PlayerViewModel
    private let tintColor: Color?
    private let onDismiss: () -> Void

    private var hasLaunched = false

    /// Engine-owned render surface. Mounted into `contentOverlayView`
    /// only when the engine reports the software (dav1d) backend; for
    /// the native path AVKit's own AVPlayerLayer renders directly off
    /// the AVPlayer instance we hand it via `self.player`.
    private let aetherView = AetherPlayerView()
    private var aetherViewMounted = false

    /// Track our own gesture recognizers so the AVKit-suppression
    /// pass can disable everything *else* without touching ours.
    /// AVPlayerViewController attaches its own recognizers (Siri
    /// Remote arrow → 10s skip, select → play/pause toggle, touchpad
    /// pan → scrub) to self.view and its internal subviews; with
    /// chrome hidden these still fire silently and consume the
    /// presses before our handlers ever see them.
    private var ourGestureRecognizers: [UIGestureRecognizer] = []

    /// Weak ref to our SwiftUI overlay's hosting view so the chrome
    /// suppression pass can skip it. Mounted into self.view alongside
    /// AVKit's own private chrome views; the class-name heuristic in
    /// `suppressAVKitChrome` is broad enough to catch it without
    /// this guard.
    private weak var overlayHostingView: UIView?

    /// Combine subscriptions on the engine's `$currentAVPlayer` and
    /// `$playbackBackend`. currentAVPlayer fires on every internal
    /// reload (selectAudioTrack rebuilds NativeAVPlayerHost with a
    /// fresh AVPlayer); the sink rebinds AVKit's `.player` to the live
    /// instance. playbackBackend signals when to mount aetherView for
    /// the SW path.
    private var engineSubscriptions: Set<AnyCancellable> = []

    /// Freeze-frame overlay shown during audio-track-switch reload to
    /// hide the ~1 s black frame the engine teardown produces. The
    /// captured frame is video-only (via `AVPlayerItemVideoOutput`)
    /// so no UI chrome ends up in the snapshot. Faded when the new
    /// AVPlayer's timebase first advances (= audio is audible),
    /// using a periodic time observer instead of a rate KVO because
    /// the engine may set `rate=1.0` before our `$currentAVPlayer`
    /// sink registers the observation, in which case `options: [.new]`
    /// never fires. A 5 s timeout removes the overlay even if the
    /// reload fails.
    private var audioSwitchOverlay: UIView?
    private var audioSwitchTimeObserver: Any?
    private var audioSwitchObservedPlayer: AVPlayer?
    private var audioSwitchTimeoutTask: Task<Void, Never>?

    /// Per-AVPlayerItem video output attached in the `$currentAVPlayer`
    /// sink. Lets us copy the current decoded pixel buffer for the
    /// audio-switch freeze-frame snapshot without including any UI
    /// chrome (the old `UIView.snapshotView` path captured the
    /// SwiftUI overlay + AVKit chrome along with the video). Ring
    /// buffer is small (4-5 frames at source resolution); cost is
    /// ~10-40 MB at 720p-1080p, more at 4K HDR.
    private var playerVideoOutput: AVPlayerItemVideoOutput?
    private var playerVideoOutputItem: AVPlayerItem?
    private let pixelBufferRenderContext = CIContext(options: nil)

    /// True only between `didEnterBackground` and the next
    /// `didBecomeActive`. The Apple TV app switcher (double Home)
    /// fires `willResignActive` but NOT `didEnterBackground`, so it
    /// leaves this false, and we use that signal to skip the
    /// reload-and-pause routine. Pure full-background returns
    /// (Home button, screensaver, AirPlay nag handing focus away)
    /// keep the existing pause-on-resume behaviour.
    private var wasFullyBackgrounded = false

    init(
        viewModel: PlayerViewModel,
        tintColor: Color? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.tintColor = tintColor
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // AVKit configuration. showsPlaybackControls = true is
        // REQUIRED on tvOS to activate AVKit's internal Now Playing
        // session + AirPods detection + Enhance Dialogue + Atmos
        // sync. We suppress every visible chrome element so our
        // custom UI dominates:
        //   - transport bar hidden via the subset flag
        //   - info views (top swipe-down) hidden via the subset flag
        //   - contextual menu emptied
        //
        // `appliesPreferredDisplayCriteriaAutomatically = true` plus
        // `LoadOptions.suppressDisplayCriteria = true` in
        // PlayerViewModel: AVKit is the sole criteria writer, the
        // engine pre-flight is OFF. AVKit reads the live
        // AVPlayerItem.formatDescription (which has dvcC parsed
        // from the fMP4 sample entry via private CoreMedia hooks)
        // and writes the correct DV criteria for P5 / P8.1 / P8.4.
        // The engine's only criteria-related job now is to GATE
        // play() on the panel handshake settling (AetherEngine
        // 5d60dbb adds `await displayCriteria.waitForSwitch()` before
        // every `nativeHost?.play()`, with a 1000 ms Stage 1 grace
        // so AVKit's late-firing auto write is caught reliably).
        //
        // Why this architecture: empirically validated by DrHurt's
        // Build 173 testing on AetherEngine#4. Build 173 had AVKit-
        // sole-writer (same flags as here) and was the ONLY build
        // in the 159-175 sweep where SDR -> DV switching worked
        // correctly for P8.4. The synthetic CMVideoFormatDescription
        // the engine constructed for its pre-flight write had
        // BT.2020 + PQ color extensions that matched Apple's HDR10
        // mandatory triplet exactly, so the panel treated the
        // criteria as HDR10 regardless of the dvh1 FourCC. AVKit's
        // private CoreMedia path doesn't have that problem, it
        // reads dvcC directly. See research notes in this commit's
        // message for the Apple HDR Metadata For Apple Devices spec
        // citation.
        //
        // History:
        // - b1ec8839 (2026-05-24): AVKit-sole; DV5 cold-start broken
        //   because there was no play() gate.
        // - 7f225e74 (2026-05-25): engine-sole; DV8.1 broken on
        //   HDR10 panel because waitForSwitch had an async-handshake
        //   race.
        // - fd3368c8 (2026-05-25): reverted to AVKit-sole.
        // - e65f189d (2026-05-25): engine-sole again, c08dcfc fixed
        //   the race. Build 175 still showed wrong panel modes for
        //   P5 / P8.4 on DV-capable panels (extensions-triplet bug).
        // - This commit: AVKit-sole, plus engine play()-gate that
        //   waits for the panel handshake to settle before AVPlayer
        //   starts pulling frames. Lands DrHurt's Build 173 + play-
        //   delay proposal.
        //
        // Don't flip this back to false without also dropping
        // suppressDisplayCriteria=true in PlayerViewModel, otherwise
        // the engine pre-flight + AVKit auto both write criteria and
        // the late re-negotiate symptom (DrHurt Build 170) returns.
        showsPlaybackControls = true
        // iPhone Control Center 10s skip routing: AVKit only dispatches
        // CC's skip-button events into our delegate (via
        // `timeToSeekAfterUserNavigatedFrom` / `skipToNextItem`) when
        // the internal transport bar is enabled. Without this flag the
        // skip press lands at no documented entry point. Our SwiftUI
        // overlay covers AVKit's bar, so the user-visible UI stays ours
        // while CC remote skips still reach the engine.
        playbackControlsIncludeTransportBar = true
        playbackControlsIncludeInfoViews = false
        // Engine drives display criteria (LoadOptions.suppressDisplayCriteria =
        // false in PlayerViewModel). AVKit-auto would race the engine's
        // synchronous pre-flight apply() + waitForSwitch, and on tvOS 26.5+
        // the HLS variant validator rejects items synchronously at
        // playlist-parse when no display criteria are active for the
        // VIDEO-RANGE the master advertises (item.failed -11868, no errorLog
        // events, no init.mp4 fetched). Apple Tech Talk 503: criteria first,
        // THEN AVPlayerItem assignment. Engine-driven sole-writer satisfies
        // that contract; AVKit-auto cannot because it has nothing to read
        // criteria from until init.mp4 parses, which never happens if the
        // variant is rejected first.
        appliesPreferredDisplayCriteriaAutomatically = false
        contextualActions = []
        allowsPictureInPicturePlayback = false

        // skippingBehavior = .skipItem routes AVKit's internal skip
        // events to the delegate's skipToNextItem / skipToPreviousItem
        // instead of AVKit's default 10s seek (which is a no-op for
        // us — we don't have track listings). On iPhone CC the 10s
        // skip buttons may then dispatch into our delegate as well,
        // since they're driven off the same internal SkippingBehavior
        // hook.
        skippingBehavior = .skipItem
        delegate = self

        // Subscribe to engine state. currentAVPlayer drives AVKit's
        // .player rebind across audio-track-switch reloads;
        // playbackBackend drives aetherView mounting for the SW path.
        //
        // The nil case is load-bearing: for the SW (dav1d / VP9 →
        // `AVSampleBufferDisplayLayer`) path the engine never sets
        // a `currentAVPlayer`, so it transitions to nil when a
        // previous native session tore down. Without releasing
        // AVKit's reference, AVKit holds the old, item-less AVPlayer
        // and renders its own buffering spinner over our SW-decoded
        // frames — the user-visible "AV1 plays but the loading
        // indicator never goes away" bug. Setting `self.player = nil`
        // when the engine drops `currentAVPlayer` clears AVKit's
        // status machine; the AetherPlayerView (mounted into
        // `contentOverlayView` by the `playbackBackend` sink below)
        // continues rendering frames unaffected.
        let engine = viewModel.player
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] vc_rebind player=\(avPlayer == nil ? "nil" : "set") items=\(avPlayer?.currentItem?.externalMetadata.count ?? -1)")
                if let avPlayer {
                    avPlayer.allowsExternalPlayback = true
                    self.player = avPlayer
                    // AVKit re-creates its internal AVPlayerLayer for
                    // every `self.player` assignment, which resets
                    // videoGravity to the default `.resizeAspect`.
                    // Re-apply the user's picture-mode pick after each
                    // rebind so an audio-track-switch reload (which
                    // tears down the engine's nativeHost and brings up
                    // a fresh one) doesn't silently drop fill mode.
                    self.applyVideoGravity(for: self.viewModel.pictureMode)
                    // Deliberately do NOT attach AVPlayerItemVideoOutput
                    // unconditionally: keeping one attached for the full
                    // session means AVPlayer must keep decoding into a
                    // 32BGRA pixel buffer (~24 MB per 4K frame) whether
                    // we ever read it or not. That allocation pressure is
                    // the current leading suspect for the ~3.8 MB/sec
                    // RSS growth on long DV 8.1 SDR sessions that
                    // survived both the per-frame HDR scoping fix and
                    // the no-store Cache-Control fix. The output is
                    // only used by `captureCurrentVideoFrame()` at the
                    // start of an audio-track-switch (freeze-frame
                    // overlay); attach lazily in
                    // `installAudioSwitchOverlay()` and detach right
                    // after the snapshot is captured.
                    if self.audioSwitchOverlay != nil {
                        self.observeNewPlayerForAudioSwitch(avPlayer)
                    }
                } else {
                    self.player = nil
                    self.detachVideoOutput()
                }
            }
            .store(in: &engineSubscriptions)

        // Host-side freeze-frame mask for audio-track-switch reloads.
        // Fires synchronously from PlayerViewModel.selectAudioTrack
        // BEFORE the engine reload begins, so the snapshot captures
        // the still-live video surface.
        viewModel.onAudioSwitchBegin = { [weak self] in
            self?.installAudioSwitchOverlay()
        }

        // Picture-mode is applied to AVPlayerViewController directly
        // because AVKit's internal AVPlayerLayer is what renders the
        // native AVPlayer path — the engine's own AVPlayerLayer (which
        // `engine.videoGravity` writes to) is allocated but never
        // mounted in this host. The callback fires on every
        // `applyPictureMode` invocation (session start, in-player
        // picker change) so the toggle takes effect within a frame.
        viewModel.onPictureModeChanged = { [weak self] mode in
            self?.applyVideoGravity(for: mode)
        }
        // Seed the initial gravity from whatever the VM has resolved
        // before this VC's init. `applyPictureMode` may have fired
        // before our callback was wired, which would otherwise leave
        // AVKit in its default `.resizeAspect` until the user toggles
        // the picture button.
        applyVideoGravity(for: viewModel.pictureMode)

        engine.$playbackBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] backend in
                guard let self else { return }
                switch backend {
                case .software, .aether:
                    self.mountAetherViewIfNeeded()
                case .native, .none, .audio:
                    // .audio is the lean audio-only engine path: it has
                    // no video surface, so there is nothing to mount.
                    self.unmountAetherViewIfNeeded()
                }
            }
            .store(in: &engineSubscriptions)

        // End-of-content auto-dismiss: a movie or the last episode of
        // a series rolling its credits leaves a black-screen-with-no-
        // focus state behind. Route it through the same dismissPlayer
        // path the Menu button uses so the user lands back on the
        // detail view they came from.
        //
        // Fires only on natural end-of-stream (state = .idle after
        // hasStartedPlaying flipped true, with no next episode queued).
        // Error paths take state = .error which surfaces the inline
        // error overlay with its own Back button; they never reach
        // this callback. Previously gated on LogTap.isDiagnosticBuild
        // to protect a tester-screenshot use case for fast-erroring
        // sessions that no longer flows through here, the guard left
        // TestFlight users stuck at the last second of the last
        // episode of a series.
        viewModel.onPlaybackReachedEnd = { [weak self] in
            Task { @MainActor in
                self?.dismissPlayer()
            }
        }

        // SwiftUI overlays (display-only). `.tint(...)` has to be
        // applied here because this hosted view lives in a UIKit modal,
        // the WindowGroup tint set on SodaliteApp never reaches it.
        let overlay = PlayerOverlayView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismissPlayer() }
        )
            .tint(tintColor)
        let hosting = UIHostingController(rootView: overlay)
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)
        overlayHostingView = hosting.view

        // Gesture recognizers for ALL buttons including Menu
        addPressGesture(.select, action: #selector(selectPressed))
        addPressGesture(.playPause, action: #selector(playPausePressed))
        addPressGesture(.menu, action: #selector(menuPressed))
        // left/right: a short click is a discrete skip, holding it spools
        // continuously (hold-to-seek). The tap requires the hold to fail so
        // a quick click never starts a spool.
        let leftTap = addPressGesture(.leftArrow, action: #selector(leftPressed))
        let leftHold = addHoldGesture(.leftArrow, action: #selector(leftHeld(_:)))
        leftTap.require(toFail: leftHold)
        let rightTap = addPressGesture(.rightArrow, action: #selector(rightPressed))
        let rightHold = addHoldGesture(.rightArrow, action: #selector(rightHeld(_:)))
        rightTap.require(toFail: rightHold)
        addPressGesture(.upArrow, action: #selector(upPressed))
        addPressGesture(.downArrow, action: #selector(downPressed))

        // Touchpad pan gesture
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        ourGestureRecognizers.append(pan)

        // Background → engine stops demux loop (VT + AVIO die in suspension)
        // Foreground → reload pipeline at current position
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        // Distinguishes a real background trip (Home button, sleep,
        // screensaver wake) from a transient inactive state like
        // the Apple TV app switcher. didEnterBackground only fires
        // for the former.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    /// Map the host's picture-mode enum to AVKit's videoGravity and
    /// apply it directly to this AVPlayerViewController. AVKit owns
    /// the on-screen AVPlayerLayer for the native path, so this is
    /// the surface the gravity actually needs to land on. The engine's
    /// own `nativeHost.playerLayer` carries the same value (set by
    /// the engine's videoGravity setter) but that layer is unmounted
    /// in this host configuration.
    private func applyVideoGravity(for mode: PlaybackPreferences.PictureMode) {
        switch mode {
        case .original: self.videoGravity = .resizeAspect
        case .fill:     self.videoGravity = .resizeAspectFill
        }
    }

    /// Add aetherView to AVKit's contentOverlayView for the software
    /// (AVSampleBufferDisplayLayer / dav1d) path. Idempotent.
    /// contentOverlayView sits between AVKit's player layer and its
    /// chrome layer, so engine frames render on top of AVKit's empty
    /// player surface and below our SwiftUI overlay (which lives on
    /// self.view above contentOverlayView).
    private func mountAetherViewIfNeeded() {
        guard !aetherViewMounted else { return }
        let host = contentOverlayView ?? view!
        host.insertSubview(aetherView, at: 0)
        aetherView.frame = host.bounds
        aetherView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        viewModel.player.bind(view: aetherView)
        aetherViewMounted = true
    }

    private func unmountAetherViewIfNeeded() {
        guard aetherViewMounted else { return }
        viewModel.player.unbind(view: aetherView)
        aetherView.removeFromSuperview()
        aetherViewMounted = false
    }

    // MARK: - Audio-track-switch freeze-frame overlay

    /// Attach a video-only output to the player's current item. Lets
    /// `installAudioSwitchOverlay` copy the most recent decoded pixel
    /// buffer for the freeze-frame snapshot without dragging the UI
    /// chrome along (the `UIView.snapshotView` path captured the
    /// SwiftUI overlay too). Detached + reattached on every engine
    /// reload because each reload produces a fresh AVPlayerItem.
    private func attachVideoOutput(for player: AVPlayer) {
        guard let item = player.currentItem else {
            detachVideoOutput()
            return
        }
        if playerVideoOutputItem === item, playerVideoOutput != nil { return }
        detachVideoOutput()
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        playerVideoOutput = output
        playerVideoOutputItem = item
    }

    private func detachVideoOutput() {
        if let output = playerVideoOutput, let item = playerVideoOutputItem {
            item.remove(output)
        }
        playerVideoOutput = nil
        playerVideoOutputItem = nil
    }

    /// Copy the most recent decoded frame from the attached
    /// `AVPlayerItemVideoOutput`. Returns nil if no output is
    /// attached, no buffer is available, or the conversion fails;
    /// caller treats nil as "no overlay this round" and the user
    /// sees the regular black frame (no worse than pre-overlay
    /// behaviour).
    private func captureCurrentVideoFrame() -> UIImage? {
        guard let output = playerVideoOutput, let player = self.player else {
            return nil
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard let buffer = output.copyPixelBuffer(
            forItemTime: time,
            itemTimeForDisplay: nil
        ) ?? output.copyPixelBuffer(
            forItemTime: player.currentTime(),
            itemTimeForDisplay: nil
        ) else {
            return nil
        }
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = pixelBufferRenderContext.createCGImage(
            ciImage,
            from: ciImage.extent
        ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Pin the captured pixel-buffer frame over the video surface so
    /// the user sees a frozen video frame (no UI chrome) instead of
    /// a black frame while the engine tears down + restarts the
    /// pipeline. Removed when the new AVPlayer's `rate` goes
    /// non-zero (engine called `.play()`), or by the 5 s timeout.
    private func installAudioSwitchOverlay() {
        guard audioSwitchOverlay == nil else { return }
        guard let image = captureCurrentVideoFrame() else { return }
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        let host = contentOverlayView ?? view!
        imageView.frame = host.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isUserInteractionEnabled = false
        imageView.backgroundColor = .black
        // contentOverlayView sits above AVPlayer's video layer but
        // below AVKit chrome; the SwiftUI overlay is on self.view
        // directly so it stays above this snapshot too.
        host.addSubview(imageView)
        audioSwitchOverlay = imageView

        audioSwitchTimeoutTask?.cancel()
        audioSwitchTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.removeAudioSwitchOverlay(animated: false)
        }
    }

    /// Attach a periodic time observer to the new AVPlayer; fade as
    /// soon as the player's timebase advances past its starting
    /// position. The first observer callback fires immediately with
    /// `currentTime() == startTime` (skipped); the next callback
    /// fires once playback actually starts producing samples. This
    /// reliably catches the audio-resume moment regardless of when
    /// the engine called `.play()`, which a rate KVO can miss if
    /// rate is set before our sink registers.
    private func observeNewPlayerForAudioSwitch(_ player: AVPlayer) {
        cleanupAudioSwitchObservation()
        let startTime = player.currentTime()
        audioSwitchObservedPlayer = player
        audioSwitchTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] currentTime in
            guard let self else { return }
            guard currentTime.isNumeric, startTime.isNumeric else { return }
            guard CMTimeCompare(currentTime, startTime) > 0 else { return }
            self.removeAudioSwitchOverlay(animated: true)
        }
    }

    private func cleanupAudioSwitchObservation() {
        if let observer = audioSwitchTimeObserver,
           let player = audioSwitchObservedPlayer {
            player.removeTimeObserver(observer)
        }
        audioSwitchTimeObserver = nil
        audioSwitchObservedPlayer = nil
    }

    private func removeAudioSwitchOverlay(animated: Bool) {
        audioSwitchTimeoutTask?.cancel()
        audioSwitchTimeoutTask = nil
        cleanupAudioSwitchObservation()
        guard let snap = audioSwitchOverlay else { return }
        audioSwitchOverlay = nil
        if animated {
            UIView.animate(
                withDuration: 0.25,
                animations: { snap.alpha = 0 },
                completion: { _ in snap.removeFromSuperview() }
            )
        } else {
            snap.removeFromSuperview()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Kick off playback as the modal *starts* appearing instead of
        // waiting for the appear animation to fully complete. The
        // present() call uses animated:false so the gap is small, but
        // every ms of network/demuxer work that overlaps with the
        // present-then-layout sequence is one ms the user doesn't
        // wait at the end.
        guard !hasLaunched else { return }
        hasLaunched = true
        // Tracked launch: a back-press during the loading spinner cancels
        // this task (and latches teardown) so the in-flight load can't
        // resume into player.load() after dismissal and leave audio
        // playing behind a gone player.
        viewModel.beginPlayback()
    }

    @discardableResult
    private func addPressGesture(_ type: UIPress.PressType, action: Selector) -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer(target: self, action: action)
        tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(tap)
        ourGestureRecognizers.append(tap)
        return tap
    }

    /// A long-press recognizer for a directional press, so holding left /
    /// right continuously spools (hold-to-seek) while a short click stays a
    /// discrete skip. The matching tap is set to require this to fail, so a
    /// quick click is a skip and a held click is a spool.
    @discardableResult
    private func addHoldGesture(_ type: UIPress.PressType, action: Selector) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer(target: self, action: action)
        hold.allowedPressTypes = [NSNumber(value: type.rawValue)]
        hold.minimumPressDuration = 0.35
        view.addGestureRecognizer(hold)
        ourGestureRecognizers.append(hold)
        return hold
    }

    /// Walk self.view and its internal AVKit-owned subviews disabling
    /// every gesture recognizer that isn't one of ours. Called from
    /// viewDidAppear once AVKit has finished wiring its built-in
    /// recognizers (arrow → 10s skip, touchpad pan → scrub, select →
    /// play/pause toggle, etc.); without this the chrome stays
    /// invisible but the gestures still fire silently, consuming
    /// presses before our handlers see them. Idempotent.
    private func suppressAVKitGestures() {
        let ours = Set(ourGestureRecognizers.map { ObjectIdentifier($0) })
        suppressGestures(on: view, exclude: ours)
    }

    private func suppressGestures(on v: UIView, exclude: Set<ObjectIdentifier>) {
        if let grs = v.gestureRecognizers {
            for gr in grs where !exclude.contains(ObjectIdentifier(gr)) {
                gr.isEnabled = false
            }
        }
        for sub in v.subviews {
            suppressGestures(on: sub, exclude: exclude)
        }
    }

    /// Walk self.view, find AVKit's chrome views (transport bar, info
    /// view) and force them to alpha=0. We need
    /// `playbackControlsIncludeTransportBar = true` on tvOS for AVKit
    /// to wire the iPhone Control Center 10s skip handler (Now Playing
    /// session forwards CC's skipForward / skipBackward commands only
    /// when the transport-bar flag is set). With the flag true AVKit
    /// also renders its own chrome on user interaction, doubling with
    /// our custom transport bar. The skip handler lives on
    /// `AVPlayerViewController` itself, not on the chrome views, so
    /// hiding the chrome optically (alpha=0) doesn't break CC skips.
    /// Class-name string matching is runtime introspection, not
    /// private-API selector dispatch; App Store review consistently
    /// allows this pattern.
    private func suppressAVKitChrome() {
        let preserved: Set<ObjectIdentifier> = {
            var ids: Set<ObjectIdentifier> = [
                ObjectIdentifier(aetherView)
            ]
            if let host = overlayHostingView {
                ids.insert(ObjectIdentifier(host))
            }
            if let overlay = contentOverlayView {
                ids.insert(ObjectIdentifier(overlay))
            }
            return ids
        }()
        hideChrome(on: view, preserve: preserved)
    }

    private func hideChrome(on v: UIView, preserve: Set<ObjectIdentifier>) {
        if preserve.contains(ObjectIdentifier(v)) { return }
        let typeName = String(describing: type(of: v))
        // Keyword set tuned against the runtime view hierarchy AVKit
        // builds on tvOS:
        //   - `_AVPlayerControlsView`      → transport bar / play-pause
        //   - `_AVPlayerTransportBarView`  → scrubber band
        //   - `_AVPlayerInfoView`          → title + subtitle text
        //   - `AVInfoMenuCell`             → audio / subtitle picker rows
        //   - `_AVFocusContainerView`      → wraps the chrome stack so
        //                                    the focus engine can find it
        //   - `_AVPlayerViewControllerContainerView` → wraps the focus
        //                                    container; matching `Container`
        //                                    here would be too broad, so we
        //                                    match Focus instead and walk
        //                                    upward via the Focus match.
        let isChrome = typeName.contains("Controls")
            || typeName.contains("Transport")
            || typeName.contains("Chrome")
            || typeName.contains("Info")
            || typeName.contains("Focus")
            || typeName.contains("Menu")
        if isChrome {
            v.alpha = 0
            return
        }
        for sub in v.subviews {
            hideChrome(on: sub, preserve: preserve)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        suppressAVKitGestures()
        suppressAVKitChrome()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVKit re-attaches recognizers on layout passes (eg. rotation,
        // bounds changes). Re-run the suppression so they don't sneak
        // back in. Cheap enough to call every layout; the inner walk
        // is shallow.
        suppressAVKitGestures()
        // Chrome views fade in/out on interaction; re-zero the alpha on
        // every layout pass to snap them back to invisible. Won't catch
        // mid-animation alpha values between layout passes, but covers
        // the steady state after AVKit's fade transitions settle.
        suppressAVKitChrome()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Only stop playback if the VC is actually being dismissed.
        // Display mode switches (HDR/SDR) briefly trigger viewWillDisappear
        // without actually dismissing, don't kill playback for that.
        guard isBeingDismissed || isMovingFromParent else { return }
        unmountAetherViewIfNeeded()
        // Release AVKit's hosting + the explicit MPNowPlayingSession
        // (cleared by stopPlayback below).
        player = nil
        viewModel.stopPlayback()
    }

    @objc private func appDidEnterBackground() {
        wasFullyBackgrounded = true
    }

    @objc private func appDidBecomeActive() {
        guard viewModel.hasStartedPlaying else { return }

        // App switcher (double Home, swipe between recents) lands
        // here without ever firing didEnterBackground. The decoder
        // sessions are still alive, the audio is still synced, so
        // there's nothing to rebuild and nothing to pause, let
        // playback continue uninterrupted.
        guard wasFullyBackgrounded else { return }
        wasFullyBackgrounded = false

        // tvOS deactivates the app's AVAudioSession on background.
        // Without an explicit re-activation here, the post-reload
        // pause()/resume() sequence drives a synchronizer whose
        // audio renderer has no live session to push samples
        // through, the user pressed Play, the state machine
        // flipped to .playing, but no audio came out and no
        // frames advanced. Re-arming the session before the
        // pipeline rebuild fixes it.
        try? AVAudioSession.sharedInstance().setActive(true)

        // Real background return: VT + AVIO sessions are dead, so
        // reload the pipeline from the current position. After the
        // reload, hold the player paused on the resumed frame and
        // surface the controls so the user has to press Play
        // deliberately, auto-resuming after a sleep / Home /
        // screensaver gap is startling.
        //
        // No artificial settle delay needed any more, AetherEngine's
        // load() now blocks until audio is genuinely flowing through
        // the pipeline (or 2s timeout) before resuming the caller,
        // so pause() right after has a fully wired-up synchronizer
        // to operate on.
        Task { @MainActor in
            try? await viewModel.player.reloadAtCurrentPosition()
            viewModel.player.pause()
            viewModel.showControlsTemporarily()
        }
    }

    // MARK: - Press Handlers (state machine)

    /// Stats side panel captures every press while mounted: it isn't
    /// focusable in the SwiftUI sense (the transport bar's @objc press
    /// gestures stand between SwiftUI and the remote), so navigation
    /// has to be routed at the press-handler level. Up/down scroll the
    /// panel through its section anchors, select and menu dismiss it,
    /// left/right are intentionally inert (no horizontal nav).
    private var statsOverlayCapturesPresses: Bool {
        viewModel.showStatsOverlay
    }

    /// Indices into `PlayerViewModel.statsSectionAnchors` whose
    /// matching section is currently rendered for this source. Mirrors
    /// the @ViewBuilder gates inside `StatsOverlayView`:
    /// - 0 playback: always rendered
    /// - 1 video: media has a video stream
    /// - 2 audio: media has an active audio track
    /// - 3 subtitle: subtitles are on
    /// - 4 file: media source is present
    /// Used by `advanceStatsCursor` so up/down steps land only on
    /// anchors that actually have a view to scroll to; otherwise
    /// `ScrollViewReader.scrollTo` no-ops silently and the user sees
    /// the cursor "stick" on that step (Vincent's "up doesn't work"
    /// repro).
    private var availableStatsSectionIndices: [Int] {
        var indices: [Int] = []
        // 0 — Live is always rendered (the panel only appears when stats are on).
        indices.append(0)
        // 1 — Playback (always)
        indices.append(1)
        let item = viewModel.item
        if item.mediaStreams?.contains(where: { $0.type == .video }) == true {
            indices.append(2)
        }
        let hasEngineAudio = viewModel.player.audioTracks.contains {
            $0.id == viewModel.player.activeAudioTrackIndex
        }
        let hasJellyfinAudio = item.mediaStreams?.contains(where: { $0.type == .audio }) == true
        if hasEngineAudio || hasJellyfinAudio {
            indices.append(3)
        }
        if viewModel.activeSubtitleIndex != nil {
            indices.append(4)
        }
        if item.mediaSources?.first != nil {
            indices.append(5)
        }
        if viewModel.preferences.showEngineDiagnostics {
            indices.append(6)
            indices.append(7)
            indices.append(8)
        }
        return indices
    }

    /// Step the stats cursor by `delta` through `availableStatsSectionIndices`
    /// so each up/down press lands on the next rendered anchor. Clamps
    /// at the ends. If the current index isn't in the available list
    /// (which can happen briefly when subtitles are toggled while the
    /// overlay is open), snaps to the closest available index instead
    /// of getting stuck.
    private func advanceStatsCursor(by delta: Int) {
        let avail = availableStatsSectionIndices
        guard !avail.isEmpty else { return }
        let current = viewModel.statsSectionIndex
        let pos: Int
        if let exact = avail.firstIndex(of: current) {
            pos = exact
        } else {
            // Current index dropped out of the rendered set. Snap to
            // the closest available position by absolute distance.
            pos = avail.enumerated().min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 0
        }
        let newPos = max(0, min(avail.count - 1, pos + delta))
        viewModel.statsSectionIndex = avail[newPos]
    }

    @objc private func selectPressed() {
        // Stats panel: Select closes it like Menu does. The chip on
        // the transport bar still toggles when the panel is closed,
        // but with the panel open every press goes here first.
        if statsOverlayCapturesPresses {
            viewModel.showStatsOverlay = false
            return
        }
        // Skip Intro takes priority over any transient scrub state.
        // The Siri Remote touchpad reports a tiny pan in the milliseconds
        // before its click registers, easily past the 40pt scrub
        // threshold, which flips both showControls and isScrubbing
        // true. Without this guard the user's tap to dismiss the intro
        // would land in the commit-scrub branch and reopen the player
        // UI instead of skipping. The hint overlay only shows when
        // controls are hidden + the dropdown is closed, so we use the
        // same gate to detect "user clearly intends Skip Intro" and
        // discard the bogus partial scrub before acting.
        if viewModel.isInsideIntro && !viewModel.isDropdownOpen
           && (!viewModel.showControls || viewModel.controlsFocus == .progressBar) {
            if viewModel.isScrubbing { viewModel.cancelScrub() }
            viewModel.skipIntro()
            return
        }

        // Next-episode commandeers Select only when the transport is
        // hidden, otherwise the user is interacting with the control
        // overlay (scrubbing, picking a track) and a surprise next
        // would be destructive.
        if !viewModel.showControls && !viewModel.isDropdownOpen {
            if viewModel.showNextEpisodeOverlay {
                Task { await viewModel.playNextEpisode() }
                return
            }
        }
        if viewModel.isDropdownOpen {
            confirmDropdownSelection()
        } else if viewModel.showControls && viewModel.controlsFocus != .progressBar {
            switch viewModel.controlsFocus {
            case .skipIntroButton: viewModel.skipIntro()
            case .chapterButton: openChapterDropdown()
            case .episodeButton: openEpisodeDropdown()
            case .audioButton: openAudioDropdown()
            case .subtitleButton: openSubtitleDropdown()
            case .speedButton: openSpeedDropdown()
            case .pictureButton: openPictureDropdown()
            case .infoButton:
                viewModel.showStatsOverlay.toggle()
                viewModel.scheduleControlsHide()
            case .returnToLiveButton:
                // Snap to the live edge, then drop focus back to the
                // scrubber: the pill disappears once isAtLiveEdge flips,
                // so leaving focus on it would strand the user on a
                // vanished control.
                viewModel.returnToLiveEdge()
                viewModel.controlsFocus = .progressBar
                viewModel.scheduleControlsHide()
            default: break
            }
        } else if viewModel.isScrubbing {
            viewModel.commitScrub()
        } else if viewModel.showControls {
            viewModel.togglePlayPause()
        } else {
            viewModel.showControlsTemporarily()
        }
    }

    @objc private func playPausePressed() {
        viewModel.togglePlayPause()
    }

    @objc private func menuPressed() {
        // Cancelling the next-episode countdown only hijacks Menu when
        // the transport is hidden. With controls open, Menu behaves
        // normally (close dropdown → abort scrub → step focus → hide
        // controls) and the countdown keeps running in the corner.
        if viewModel.showNextEpisodeOverlay && !viewModel.showControls && !viewModel.isDropdownOpen {
            viewModel.cancelNextEpisode()
            return
        }
        // Stats panel intercepts Menu when it's the only thing open,
        // same pattern as the next-episode prompt. Same press still
        // counts as "close the stats panel" rather than "exit the
        // player", so a curious user who toggled the panel can dismiss
        // it without losing their place.
        if viewModel.showStatsOverlay {
            viewModel.showStatsOverlay = false
            return
        }
        if viewModel.isDropdownOpen {
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        } else if viewModel.isScrubbing {
            viewModel.cancelScrub()
        } else if viewModel.showControls {
            if viewModel.controlsFocus != .progressBar {
                viewModel.controlsFocus = .progressBar
            } else {
                viewModel.hideControls()
            }
        } else {
            dismissPlayer()
        }
    }

    @objc private func leftPressed() {
        // Stats panel: horizontal nav is a no-op while the panel is
        // open. No focusable rows behind it that left/right could
        // target without confusing the user about what's actually
        // capturing the press.
        if statsOverlayCapturesPresses { return }
        if viewModel.isDropdownOpen { return }
        if viewModel.showControls && viewModel.controlsFocus != .progressBar {
            stepTransportFocus(direction: -1)
            viewModel.scheduleControlsHide()
        } else {
            viewModel.seekJumpByConfiguredInterval(direction: -1)
        }
    }

    @objc private func rightPressed() {
        if statsOverlayCapturesPresses { return }
        if viewModel.isDropdownOpen { return }
        if viewModel.showControls && viewModel.controlsFocus != .progressBar {
            stepTransportFocus(direction: 1)
            viewModel.scheduleControlsHide()
        } else {
            viewModel.seekJumpByConfiguredInterval(direction: 1)
        }
    }

    @objc private func leftHeld(_ gesture: UILongPressGestureRecognizer) {
        handleHold(gesture, direction: -1)
    }

    @objc private func rightHeld(_ gesture: UILongPressGestureRecognizer) {
        handleHold(gesture, direction: 1)
    }

    /// Drive the continuous hold-to-seek spool from a directional long
    /// press: begin on `.began`, commit on release. Gated by the same
    /// conditions as the tap-skip path so a hold while navigating the
    /// transport buttons (or with the stats / dropdown up) is ignored.
    private func handleHold(_ gesture: UILongPressGestureRecognizer, direction: Int) {
        switch gesture.state {
        case .began:
            if statsOverlayCapturesPresses || viewModel.isDropdownOpen { return }
            if viewModel.showControls && viewModel.controlsFocus != .progressBar { return }
            viewModel.beginContinuousSeek(direction: direction)
        case .ended, .cancelled, .failed:
            viewModel.endContinuousSeek()
        default:
            break
        }
    }

    /// Move focus one step through the available transport buttons.
    /// Builds the list dynamically so a stream without audio or subtitle
    /// tracks still leaves speed reachable without dead stops.
    private func stepTransportFocus(direction: Int) {
        var order: [PlayerViewModel.ControlsFocus] = []
        if viewModel.isInsideIntro { order.append(.skipIntroButton) }
        if viewModel.seasonEpisodes.count > 1 { order.append(.episodeButton) }
        // Mirror TransportBar's chapter-button visibility gate, same
        // "hide on series episodes" rule, otherwise focus could land on
        // a button that isn't being rendered.
        if viewModel.chapters.count > 1, viewModel.seasonEpisodes.count <= 1 {
            order.append(.chapterButton)
        }
        if !viewModel.player.audioTracks.isEmpty { order.append(.audioButton) }
        if !viewModel.subtitleStreams.isEmpty { order.append(.subtitleButton) }
        order.append(.speedButton)
        order.append(.pictureButton)
        if viewModel.preferences.showStatsForNerds {
            order.append(.infoButton)
        }
        guard let current = order.firstIndex(of: viewModel.controlsFocus) else { return }
        let next = current + direction
        if next >= 0 && next < order.count {
            viewModel.controlsFocus = order[next]
        }
    }

    @objc private func upPressed() {
        // Stats panel: up moves the section cursor one step toward
        // the top, skipping sections that aren't currently rendered
        // (subtitle section absent when subs off, etc.). Without the
        // skip, the cursor steps into an absent anchor and the
        // ScrollViewReader's scrollTo no-ops silently, so the user
        // sees "up doesn't move" on that step. Fix: increment through
        // the *rendered* index list only.
        if statsOverlayCapturesPresses {
            advanceStatsCursor(by: -1)
            return
        }
        if viewModel.isDropdownOpen {
            moveDropdownHighlight(by: -1)
        } else if viewModel.showControls {
            switch viewModel.controlsFocus {
            case .progressBar:
                // Live: the only control above the scrubber is the
                // "Return to Live" pill, and only when behind the edge.
                // LiveTransportBar renders none of the VOD buttons, so
                // skip that whole row here.
                if viewModel.isLiveSession {
                    if !viewModel.isAtLiveEdge {
                        viewModel.controlsFocus = .returnToLiveButton
                    }
                    viewModel.scheduleControlsHide()
                    break
                }
                // Preserve scrub state, user can confirm/cancel when returning
                let hasAudio = !viewModel.player.audioTracks.isEmpty
                let hasSubs = !viewModel.subtitleStreams.isEmpty
                let hasEpisodes = viewModel.seasonEpisodes.count > 1
                // Mirror the TransportBar visibility gate, chapter
                // button is suppressed for series episodes.
                let hasChapters = viewModel.chapters.count > 1 && !hasEpisodes
                if viewModel.isInsideIntro { viewModel.controlsFocus = .skipIntroButton }
                else if hasEpisodes { viewModel.controlsFocus = .episodeButton }
                else if hasChapters { viewModel.controlsFocus = .chapterButton }
                else if hasAudio { viewModel.controlsFocus = .audioButton }
                else if hasSubs { viewModel.controlsFocus = .subtitleButton }
                else { viewModel.controlsFocus = .speedButton }
                viewModel.scheduleControlsHide()
            case .skipIntroButton, .chapterButton, .episodeButton, .audioButton, .subtitleButton, .speedButton, .pictureButton, .infoButton, .returnToLiveButton:
                viewModel.scheduleControlsHide()
            }
        } else {
            viewModel.showControlsTemporarily()
        }
    }

    @objc private func downPressed() {
        if statsOverlayCapturesPresses {
            advanceStatsCursor(by: 1)
            return
        }
        if viewModel.isDropdownOpen {
            moveDropdownHighlight(by: 1)
        } else if viewModel.showControls {
            if viewModel.controlsFocus != .progressBar {
                viewModel.controlsFocus = .progressBar
                viewModel.scheduleControlsHide()
            } else {
                viewModel.hideControls()
            }
        } else {
            viewModel.showControlsTemporarily()
        }
    }

    // MARK: - Dropdown Logic

    private func openEpisodeDropdown() {
        let episodes = viewModel.seasonEpisodes
        guard episodes.count > 1 else { return }
        viewModel.controlsTimer?.cancel()
        // Default to the active episode so the highlight starts on
        // the row the user is already watching, matching the audio
        // and speed dropdown behaviour.
        let currentIdx = episodes.firstIndex(where: { $0.id == viewModel.item.id }) ?? 0
        viewModel.trackDropdown = .episode(highlighted: currentIdx)
    }

    private func openChapterDropdown() {
        let chapters = viewModel.chapters
        guard chapters.count > 1 else { return }
        viewModel.controlsTimer?.cancel()
        // Default to the chapter currently playing so the user lands
        // on a row that matches the on-screen content rather than
        // having to scroll to find it.
        let nowSeconds = viewModel.player.currentTime
        var currentIdx = 0
        for (i, chapter) in chapters.enumerated() {
            if chapter.startSeconds <= nowSeconds + 0.001 {
                currentIdx = i
            } else {
                break
            }
        }
        viewModel.trackDropdown = .chapter(highlighted: currentIdx)
    }

    private func openAudioDropdown() {
        let tracks = viewModel.displayAudioTracks
        guard !tracks.isEmpty else { return }
        viewModel.controlsTimer?.cancel()
        let currentIdx = tracks.firstIndex(where: { $0.id == viewModel.activeAudioIndex }) ?? 0
        viewModel.trackDropdown = .audio(highlighted: currentIdx)
    }

    private func openSubtitleDropdown() {
        viewModel.controlsTimer?.cancel()
        // Items: Off (index 0), then each subtitle stream (index 1...)
        let currentIdx: Int
        if let activeId = viewModel.activeSubtitleIndex,
           let streamIdx = viewModel.displaySubtitleStreams.firstIndex(where: { $0.index == activeId }) {
            currentIdx = streamIdx + 1
        } else {
            currentIdx = 0
        }
        viewModel.trackDropdown = .subtitle(highlighted: currentIdx)
    }

    private func openSpeedDropdown() {
        viewModel.controlsTimer?.cancel()
        viewModel.trackDropdown = .speed(highlighted: viewModel.activeSpeedIndex)
    }

    private func openPictureDropdown() {
        viewModel.controlsTimer?.cancel()
        let modes = PlaybackPreferences.PictureMode.allCases
        let currentIdx = modes.firstIndex(of: viewModel.pictureMode) ?? 0
        viewModel.trackDropdown = .picture(highlighted: currentIdx)
    }

    private func moveDropdownHighlight(by offset: Int) {
        switch viewModel.trackDropdown {
        case .chapter(let idx):
            let count = viewModel.chapters.count
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .chapter(highlighted: newIdx)
        case .episode(let idx):
            let count = viewModel.seasonEpisodes.count
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .episode(highlighted: newIdx)
        case .audio(let idx):
            let count = viewModel.displayAudioTracks.count
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .audio(highlighted: newIdx)
        case .subtitle(let idx):
            let count = viewModel.displaySubtitleStreams.count + 1 // +1 for "Off"
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .subtitle(highlighted: newIdx)
        case .speed(let idx):
            let count = PlayerViewModel.speedOptions.count
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .speed(highlighted: newIdx)
        case .picture(let idx):
            let count = PlaybackPreferences.PictureMode.allCases.count
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .picture(highlighted: newIdx)
        case .none:
            break
        }
    }

    private func confirmDropdownSelection() {
        switch viewModel.trackDropdown {
        case .chapter(let idx):
            viewModel.selectChapter(at: idx)
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        case .episode(let idx):
            viewModel.trackDropdown = .none
            // Hand the actual switch off to a Task, selectEpisode tears
            // down the existing playback session and starts a fresh one
            // (network roundtrip + decoder restart). We don't want the
            // confirm-button press to block the main thread on that.
            Task { await viewModel.selectEpisode(at: idx) }
        case .audio(let idx):
            let tracks = viewModel.displayAudioTracks
            if idx < tracks.count {
                viewModel.selectAudioTrack(id: tracks[idx].id)
            }
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        case .subtitle(let idx):
            if idx == 0 {
                viewModel.selectSubtitleTrack(id: nil)
            } else {
                let streams = viewModel.displaySubtitleStreams
                let streamIdx = idx - 1
                if streamIdx < streams.count {
                    viewModel.selectSubtitleTrack(id: streams[streamIdx].index)
                }
            }
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        case .speed(let idx):
            viewModel.selectSpeed(index: idx)
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        case .picture(let idx):
            let modes = PlaybackPreferences.PictureMode.allCases
            if modes.indices.contains(idx) {
                viewModel.selectPictureMode(modes[idx])
            }
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        case .none:
            break
        }
    }

    private func dismissPlayer() {
        unmountAetherViewIfNeeded()
        player = nil
        // stopPlayback now fire-and-forgets the reportStop network
        // call so the dismiss isn't blocked on Jellyfin's slow CDN
        // response (DrHurt #12). Calling it inline (no Task wrapper)
        // means the synchronous tear-down completes before onDismiss
        // fires, so the user's back press hits the SwiftUI dismiss
        // animation immediately.
        viewModel.stopPlayback()
        onDismiss()
    }

    // MARK: - Pan (Touchpad Scrubbing)

    private enum PanAxis { case undetermined, horizontal, vertical }

    private var lastDropdownStep: CGFloat = 0
    private var panAxis: PanAxis = .undetermined
    private var verticalStepFired = false
    private var horizontalStepFired = false
    private var scrubCommitted = false

    /// Travel (pt) before we commit a pan to one axis. Low enough to
    /// feel responsive, high enough that a slightly-diagonal horizontal
    /// swipe doesn't accidentally trigger vertical navigation.
    private static let panAxisCommitThreshold: CGFloat = 40
    /// Travel (pt) on the committed vertical axis before we fire an
    /// up/down, one fire per gesture, matching the single-shot feel
    /// of pressing the arrow keys.
    private static let verticalFireThreshold: CGFloat = 150
    /// Travel (pt) on a horizontal swipe before we fire left/right when
    /// the swipe is being used for transport-button navigation rather
    /// than scrubbing, same single-shot behaviour as vertical.
    private static let horizontalFireThreshold: CGFloat = 150
    /// Minimum velocity (pt/s) for a step-firing pan to count as an
    /// intentional swipe. The Siri Remote's touchpad reports tiny
    /// finger drift while the user is just resting their finger before
    /// a click, over a second or two that drift can accumulate past
    /// the distance threshold above and steal focus to the wrong
    /// button. Requiring velocity as well filters out the slow drift
    /// case while still letting any real swipe through (typical
    /// directional swipes are well above 1000 pt/s).
    private static let stepMinVelocity: CGFloat = 400
    /// Minimum velocity (pt/s) for a horizontal pan to commit to
    /// scrubbing the timeline. Lower than stepMinVelocity because
    /// scrubbing should still trigger on a slow but deliberate drag,
    /// while the Siri Remote's resting-finger drift (roughly an order
    /// of magnitude below this) should not nudge the timeline. The
    /// gate only applies to the initial commit per gesture; once
    /// scrubbing has started the pan runs at full sensitivity.
    private static let scrubCommitMinVelocity: CGFloat = 200
    /// Finger travel (pt) on the touchpad per one item moved while an
    /// episode / chapter dropdown is open. The dropdown navigates by
    /// cumulative translation (not single-shot like button nav), so
    /// this is the sensitivity knob: bigger = more deliberate, one
    /// item per gentle swipe instead of overshooting several. Kept
    /// well above verticalFireThreshold (150) because the touchpad
    /// over-reports translation for indirect touches, so a light flick
    /// at 120 pt jumped three to four rows at once.
    private static let dropdownStepSize: CGFloat = 300

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // Stats overlay open: route vertical swipes to the section
        // cursor, swallow horizontal swipes so they don't scrub the
        // timeline behind the panel. Same gating as the @objc up /
        // down / select handlers (statsOverlayCapturesPresses).
        if statsOverlayCapturesPresses {
            switch gesture.state {
            case .began:
                panAxis = .undetermined
                verticalStepFired = false
                scrubCommitted = false
            case .changed:
                let t = gesture.translation(in: view)
                if panAxis == .undetermined {
                    let absX = abs(t.x)
                    let absY = abs(t.y)
                    if max(absX, absY) >= Self.panAxisCommitThreshold {
                        panAxis = absX > absY ? .horizontal : .vertical
                    }
                }
                if panAxis == .vertical, !verticalStepFired {
                    let v = gesture.velocity(in: view)
                    if abs(t.y) >= Self.verticalFireThreshold,
                       abs(v.y) >= Self.stepMinVelocity {
                        verticalStepFired = true
                        if t.y < 0 { upPressed() } else { downPressed() }
                    }
                }
                // Horizontal axis: swallow without acting, the overlay
                // has no left/right navigation and the user shouldn't
                // accidentally scrub the timeline behind it.
            case .ended, .cancelled:
                panAxis = .undetermined
                verticalStepFired = false
                scrubCommitted = false
            default:
                break
            }
            return
        }

        if viewModel.isDropdownOpen {
            // Vertical swipe navigates dropdown items.
            // Uses total translation divided into steps, each
            // dropdownStepSize pt of cumulative movement = one item.
            // Prevents over-scrolling on fast swipes.
            switch gesture.state {
            case .began:
                lastDropdownStep = 0
            case .changed:
                let ty = gesture.translation(in: view).y
                let stepSize = Self.dropdownStepSize
                let currentStep = (ty / stepSize).rounded(.towardZero)
                if currentStep != lastDropdownStep {
                    let steps = Int(currentStep - lastDropdownStep)
                    moveDropdownHighlight(by: steps)
                    lastDropdownStep = currentStep
                }
            case .ended, .cancelled:
                lastDropdownStep = 0
            default:
                break
            }
            return
        }

        // Lock the pan to a dominant axis on first meaningful movement
        // and then act accordingly. Vertical is always arrow-key-style
        // navigation. Horizontal is *conditional*:
        //   - progress bar focused, or controls hidden → scrub timeline
        //   - any other transport control focused → single-shot
        //     left/right navigation between control buttons
        // This lets users swipe between Skip Intro / Audio / Subs /
        // Speed without the pan being interpreted as a scrub.
        let horizontalScrubs =
            !viewModel.showControls
            || viewModel.controlsFocus == .progressBar

        switch gesture.state {
        case .began:
            panAxis = .undetermined
            verticalStepFired = false
            horizontalStepFired = false
            scrubCommitted = false
        case .changed:
            let t = gesture.translation(in: view)

            if panAxis == .undetermined {
                let absX = abs(t.x)
                let absY = abs(t.y)
                if max(absX, absY) >= Self.panAxisCommitThreshold {
                    panAxis = absX > absY ? .horizontal : .vertical
                }
            }

            switch panAxis {
            case .horizontal:
                if horizontalScrubs {
                    if !scrubCommitted {
                        let v = gesture.velocity(in: view)
                        guard abs(v.x) >= Self.scrubCommitMinVelocity else { return }
                        scrubCommitted = true
                        // Drop the drift that accumulated before commit so the
                        // first scrub frame after the gate opens starts at
                        // zero translation, not at the sub-threshold offset.
                        gesture.setTranslation(.zero, in: view)
                        return
                    }
                    let width = max(view.bounds.width, 1)
                    viewModel.scrub(delta: t.x / width)
                } else {
                    let v = gesture.velocity(in: view)
                    guard !horizontalStepFired,
                          abs(t.x) >= Self.horizontalFireThreshold,
                          abs(v.x) >= Self.stepMinVelocity
                    else { return }
                    horizontalStepFired = true
                    if t.x < 0 { leftPressed() } else { rightPressed() }
                }
            case .vertical:
                let v = gesture.velocity(in: view)
                guard !verticalStepFired,
                      abs(t.y) >= Self.verticalFireThreshold,
                      abs(v.y) >= Self.stepMinVelocity
                else { return }
                verticalStepFired = true
                if t.y < 0 { upPressed() } else { downPressed() }
            case .undetermined:
                break
            }
        case .ended, .cancelled:
            // Only finalise a scrub when the pan was actually scrubbing,
            // horizontal-into-navigation doesn't touch the timeline, so
            // no scrubPanEnded() to commit or cancel.
            if panAxis == .horizontal && horizontalScrubs {
                viewModel.scrubPanEnded()
            }
            panAxis = .undetermined
            verticalStepFired = false
            horizontalStepFired = false
            scrubCommitted = false
        default:
            break
        }
    }

}

