import SwiftUI
import AetherEngine
import AVFoundation
import AVKit
import Combine

// MARK: - Player Launcher (UIKit modal presentation)

/// Presents PlayerHostController as a UIKit modal (NOT SwiftUI fullScreenCover).
///
/// On tvOS, SwiftUI's fullScreenCover intercepts the Menu button at the
/// presentation level, pressesBegan, .onExitCommand, and gesture recognizers
/// on child VCs never receive it. UIKit modals don't have this problem:
/// UITapGestureRecognizer for .menu on the presented VC's view works.
struct PlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let item: JellyfinItem?
    let startFromBeginning: Bool
    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    var cachedPlaybackInfo: PlaybackInfoResponse?
    /// Accent color the overlay should tint with. Nil falls back to the
    /// asset-catalog default. Threaded through by callers because the
    /// WindowGroup `.tint(...)` does not cross into the UIKit modal.
    var tintColor: Color?

    func makeUIViewController(context: Context) -> PlayerLauncherHostVC {
        PlayerLauncherHostVC()
    }

    func updateUIViewController(_ host: PlayerLauncherHostVC, context: Context) {
        if isPresented, let item, host.presentedViewController == nil {
            let vm = PlayerViewModel(
                item: item,
                startFromBeginning: startFromBeginning,
                playbackService: playbackService,
                userID: userID,
                preferences: preferences,
                cachedPlaybackInfo: cachedPlaybackInfo
            )
            let playerVC = PlayerHostController(
                viewModel: vm,
                tintColor: tintColor,
                onDismiss: {
                    host.dismiss(animated: false) {
                        isPresented = false
                    }
                }
            )
            playerVC.modalPresentationStyle = .fullScreen
            host.present(playerVC, animated: false)
        } else if !isPresented, host.presentedViewController != nil {
            host.dismiss(animated: false)
        }
    }
}

/// Invisible host VC for PlayerLauncher. Only purpose: be in the
/// window hierarchy so UIKit present() works. Focus restoration is
/// handled by SwiftUI's @FocusState in the detail views.
final class PlayerLauncherHostVC: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}

// MARK: - Player View Controller

/// Full-screen video player that handles ALL Siri Remote input.
///
/// Subclasses `AVPlayerViewController` with `showsPlaybackControls
/// = true` (required on tvOS to activate AVKit's internal Now Playing
/// session auto-publish, AirPods auto-detection, Enhance Dialogue,
/// Reduce Loud Sounds, synchronized Atmos) BUT with all visible
/// chrome turned off via:
///   - `playbackControlsIncludeTransportBar = false`
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
    private let viewModel: PlayerViewModel
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
        // `appliesPreferredDisplayCriteriaAutomatically = true` is
        // load-bearing: AVKit reads each track's sample-entry codec
        // FourCC + color extensions and programs
        // `AVDisplayManager.preferredDisplayCriteria` to match, on
        // top of the engine's own pre-load assignment from
        // `DisplayCriteriaController.apply()`. AetherEngine's DV
        // classification picks `codecTagOverride` to align with
        // what AVKit will read here — bare `dvh1` for DV-capable
        // displays (P5 / P8.1 / P8.4), plain `hvc1` for SDR / HDR10
        // / HLG on non-DV displays. If you flip this to false the
        // engine still programs criteria but AVKit no longer
        // doubles up; the DV mode handshake then depends entirely
        // on the engine's one-shot pre-load `apply()` happening
        // before the panel times out its 5 s negotiation budget
        // (verified working but with less margin).
        showsPlaybackControls = true
        playbackControlsIncludeTransportBar = false
        playbackControlsIncludeInfoViews = false
        appliesPreferredDisplayCriteriaAutomatically = true
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
                case .native, .none:
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
        // Suppressed in diagnostic builds (DEBUG / TestFlight) so the
        // log overlay remains readable after a failed-start session.
        // Without this, a session that errors out within a second of
        // launch dismisses the player before the tester can screenshot
        // the diagnostic overlay (DrHurt: "Error messages literally
        // flash for less than 1 sec before going back to movie info
        // screen"). Menu still dismisses manually. App Store builds
        // keep the auto-dismiss so end users aren't stranded on a
        // black screen.
        viewModel.onPlaybackReachedEnd = { [weak self] in
            Task { @MainActor in
                guard !LogTap.isDiagnosticBuild else { return }
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

        // Gesture recognizers for ALL buttons including Menu
        addPressGesture(.select, action: #selector(selectPressed))
        addPressGesture(.playPause, action: #selector(playPausePressed))
        addPressGesture(.menu, action: #selector(menuPressed))
        addPressGesture(.leftArrow, action: #selector(leftPressed))
        addPressGesture(.rightArrow, action: #selector(rightPressed))
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
        Task { await viewModel.startPlayback() }
    }

    private func addPressGesture(_ type: UIPress.PressType, action: Selector) {
        let tap = UITapGestureRecognizer(target: self, action: action)
        tap.allowedPressTypes = [NSNumber(value: type.rawValue)]
        view.addGestureRecognizer(tap)
        ourGestureRecognizers.append(tap)
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        suppressAVKitGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // AVKit re-attaches recognizers on layout passes (eg. rotation,
        // bounds changes). Re-run the suppression so they don't sneak
        // back in. Cheap enough to call every layout; the inner walk
        // is shallow.
        suppressAVKitGestures()
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
        Task { await viewModel.stopPlayback() }
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
        // the top. ScrollViewReader inside StatsOverlayView watches
        // `statsSectionIndex` and scrolls to the corresponding anchor.
        if statsOverlayCapturesPresses {
            let count = PlayerViewModel.statsSectionAnchors.count
            viewModel.statsSectionIndex = max(0, min(count - 1, viewModel.statsSectionIndex - 1))
            return
        }
        if viewModel.isDropdownOpen {
            moveDropdownHighlight(by: -1)
        } else if viewModel.showControls {
            switch viewModel.controlsFocus {
            case .progressBar:
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
            case .skipIntroButton, .chapterButton, .episodeButton, .audioButton, .subtitleButton, .speedButton, .pictureButton, .infoButton:
                viewModel.scheduleControlsHide()
            }
        } else {
            viewModel.showControlsTemporarily()
        }
    }

    @objc private func downPressed() {
        if statsOverlayCapturesPresses {
            let count = PlayerViewModel.statsSectionAnchors.count
            viewModel.statsSectionIndex = max(0, min(count - 1, viewModel.statsSectionIndex + 1))
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
        let tracks = viewModel.player.audioTracks
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
           let streamIdx = viewModel.subtitleStreams.firstIndex(where: { $0.index == activeId }) {
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
            let count = viewModel.player.audioTracks.count
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .audio(highlighted: newIdx)
        case .subtitle(let idx):
            let count = viewModel.subtitleStreams.count + 1 // +1 for "Off"
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
            let tracks = viewModel.player.audioTracks
            if idx < tracks.count {
                viewModel.selectAudioTrack(id: tracks[idx].id)
            }
            viewModel.trackDropdown = .none
            viewModel.scheduleControlsHide()
        case .subtitle(let idx):
            if idx == 0 {
                viewModel.selectSubtitleTrack(id: nil)
            } else {
                let streams = viewModel.subtitleStreams
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
        Task {
            await viewModel.stopPlayback()
            onDismiss()
        }
    }

    // MARK: - Pan (Touchpad Scrubbing)

    private enum PanAxis { case undetermined, horizontal, vertical }

    private var lastDropdownStep: CGFloat = 0
    private var panAxis: PanAxis = .undetermined
    private var verticalStepFired = false
    private var horizontalStepFired = false

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

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if viewModel.isDropdownOpen {
            // Vertical swipe navigates dropdown items.
            // Uses total translation divided into steps, each 120pt of
            // cumulative movement = one item. Prevents over-scrolling
            // on fast swipes.
            switch gesture.state {
            case .began:
                lastDropdownStep = 0
            case .changed:
                let ty = gesture.translation(in: view).y
                let stepSize: CGFloat = 120
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
        default:
            break
        }
    }

}

// MARK: - AVPlayerViewControllerDelegate (skip routing)

extension PlayerHostController: AVPlayerViewControllerDelegate {
    /// `skippingBehavior = .skipItem` was the last documented Apple-
    /// API attempt to route iPhone Control Center's 10s skip buttons
    /// into our code. Verified on device: CC press does NOT dispatch
    /// here. AVKit's internal Now Playing session enables the
    /// skipForwardCommand on its own per-session command center
    /// (which is why CC shows the buttons) but binds them to an
    /// internal no-op handler we have no documented way to override.
    /// Kept as the safe fallback in case other AVKit pathways (Siri
    /// Remote skipItem chord, future tvOS evolution) actually fire
    /// here — we'd rather seek than no-op.
    func skipToNextItem(for playerViewController: AVPlayerViewController) {
        print("[NowPlaying] delegate skipToNextItem fired (+10s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = self.viewModel.player.currentTime + 10
            await self.viewModel.player.seek(to: target)
        }
    }

    func skipToPreviousItem(for playerViewController: AVPlayerViewController) {
        print("[NowPlaying] delegate skipToPreviousItem fired (-10s)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = max(0, self.viewModel.player.currentTime - 10)
            await self.viewModel.player.seek(to: target)
        }
    }

    /// The Apple-documented "skip-style navigation" delegate hook.
    /// Forum thread 651497 (Apple Media Engineer answering): this is
    /// "the API that controls skip +/- 10". Description suggests it
    /// fires for any user-initiated skip navigation — possibly
    /// including iPhone Control Center. Return value modifies WHERE
    /// the seek lands (return targetTime unmodified to let AVKit's
    /// default seek go through; return oldTime to block).
    /// Logging both args so we can verify CC dispatches here.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        timeToSeekAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) -> CMTime {
        print("[NowPlaying] delegate timeToSeek from=\(oldTime.seconds) to=\(targetTime.seconds)")
        return targetTime
    }

    /// Companion notification hook: fires when the user-initiated
    /// navigation resumes playback. Combined with timeToSeek above
    /// they document AVKit's skip-navigation pipeline.
    nonisolated func playerViewController(
        _ playerViewController: AVPlayerViewController,
        willResumePlaybackAfterUserNavigatedFrom oldTime: CMTime,
        to targetTime: CMTime
    ) {
        print("[NowPlaying] delegate willResumePlayback from=\(oldTime.seconds) to=\(targetTime.seconds)")
    }
}

// MARK: - Overlay View (display-only SwiftUI)

private struct PlayerOverlayView: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            if !viewModel.subtitleCues.isEmpty {
                SubtitleOverlayView(
                    cues: viewModel.subtitleCues,
                    currentTime: viewModel.subtitleTime,
                    fontSize: viewModel.preferences.subtitleFontSize,
                    textColor: viewModel.preferences.subtitleColor,
                    background: viewModel.preferences.subtitleBackground,
                    delaySeconds: viewModel.preferences.subtitleDelaySeconds,
                    verticalOffsetPoints: viewModel.preferences.subtitleVerticalOffsetPoints
                )
            }

            if viewModel.isLoading {
                Color.black
                    .ignoresSafeArea()
                    .overlay(ProgressView())
                    .transition(.opacity)
            }

            if let error = viewModel.errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: viewModel.errorIcon ?? "exclamationmark.triangle")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    if let title = viewModel.errorTitle {
                        Text(title)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                    }
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 720)
                    Button {
                        onDismiss()
                    } label: {
                        Text("player.error.back")
                            .font(.body)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(SettingsTileButtonStyle())
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .transition(.opacity)
            }

            if viewModel.showControls && !viewModel.isLoading && viewModel.errorMessage == nil {
                controlsOverlay
            }

            // Stats-for-nerds side panel (right-anchored). Mounted on
            // top of the controls overlay so it stays readable when the
            // transport bar's auto-hide timer fires; press the info
            // chip or Menu to dismiss.
            if viewModel.showStatsOverlay && viewModel.errorMessage == nil {
                StatsOverlayView(
                    player: viewModel.player,
                    item: viewModel.item,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    scrollSectionIndex: viewModel.statsSectionIndex
                )
            }

            // Top-right info column, HDR badge (only with controls,
            // matches Apple TV's own player) and Speed badge (always
            // when rate ≠ 1.0× so the user remembers they sped things
            // up after the transport hides). Stacks vertically when
            // both are visible.
            topRightInfoColumn

            // Diagnostic log overlay (top-left). Two-gate: the build
            // has to be DEBUG or TestFlight (App Store users can't
            // even toggle this on), AND the user has to have flipped
            // showDiagnosticOverlay in Settings, which defaults off
            // so the overlay isn't on top of every TestFlight session.
            if LogTap.isDiagnosticBuild && viewModel.preferences.showDiagnosticOverlay {
                DiagnosticLogOverlay()
            }

            // Floating Skip Intro hint, only while the full controls
            // are hidden. When they open, the skip action becomes a
            // proper focusable button inside TransportBar instead.
            if viewModel.isInsideIntro
                && !viewModel.showControls
                && viewModel.errorMessage == nil
                && !viewModel.showNextEpisodeOverlay {
                introSkipOverlay
            }

            // Next episode overlay
            if viewModel.showNextEpisodeOverlay,
               let next = viewModel.nextEpisode {
                nextEpisodeOverlay(next)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.isLoading)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.3), value: viewModel.showNextEpisodeOverlay)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isInsideIntro)
        .animation(.easeInOut(duration: 0.25), value: viewModel.showStatsOverlay)
    }

    private var introSkipOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "forward.end.fill")
                        .font(.body)
                    Text(String(localized: "player.skipIntro", defaultValue: "Skip Intro"))
                        .font(.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
                .padding(.trailing, 80)
                .padding(.bottom, 80)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .allowsHitTesting(false)
    }

    private func nextEpisodeOverlay(_ episode: JellyfinItem) -> some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                cardBody(for: episode)
                    .padding(.trailing, viewModel.showControls ? 60 : 40)
                    .padding(.bottom, viewModel.showControls ? 300 : 40)
            }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    private func cardBody(for episode: JellyfinItem) -> some View {
        ZStack(alignment: .topLeading) {
            // Backdrop: episode thumbnail, dimmed so text stays
            // legible. Without an explicit frame + clipped() the
            // AsyncImage's intrinsic size leaks into ZStack sizing
            // and a portrait thumbnail (e.g. when only a series
            // poster is available as fallback) blows the card up
            // into a tall portrait.
            if let imageURL = episodeThumbnailURL(for: episode) {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.clear
                }
                .frame(width: 380, height: 214)
                .clipped()
                .opacity(0.4)
            }

            // Foreground text content. .topLeading alignment + Spacer
            // distribute header / title / countdown across the card
            // height instead of bunching them in the centre.
            VStack(alignment: .leading, spacing: 0) {
                Text(String(localized: "player.nextEpisode", defaultValue: "Next Episode"))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if let s = episode.parentIndexNumber, let e = episode.indexNumber {
                        Text("S\(s)E\(e)")
                            .foregroundStyle(.white.opacity(0.85))
                            .layoutPriority(1)
                    }
                    Text(episode.name)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                .font(.body)
                .fontWeight(.semibold)

                Spacer(minLength: 8)

                if viewModel.isCountdownActive, viewModel.nextEpisodeCountdown > 0 {
                    Text("player.nextEpisode.countdown \(viewModel.nextEpisodeCountdown)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
            .padding(20)
            .frame(width: 380, height: 214, alignment: .topLeading)
        }
        // Fixed 16:9 card. Both the image and the content above use
        // the same explicit 380x214 frame, so the ZStack itself is
        // exactly that size, nothing intrinsic-leaking can stretch
        // it into a portrait.
        .frame(width: 380, height: 214)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    /// Build episode thumbnail URL directly from item data
    /// (avoids needing JellyfinImageService in the player).
    private func episodeThumbnailURL(for item: JellyfinItem) -> URL? {
        guard let baseURL = viewModel.playbackService.baseURL else { return nil }
        if let tag = item.imageTags?.primary {
            return URL(string: "\(baseURL)/Items/\(item.id)/Images/Primary?tag=\(tag)&maxWidth=640&quality=80")
        }
        if let tags = item.backdropImageTags, let tag = tags.first {
            return URL(string: "\(baseURL)/Items/\(item.id)/Images/Backdrop?tag=\(tag)&maxWidth=640&quality=80")
        }
        if let tags = item.parentBackdropImageTags, let tag = tags.first, let seriesId = item.seriesId {
            return URL(string: "\(baseURL)/Items/\(seriesId)/Images/Backdrop?tag=\(tag)&maxWidth=640&quality=80")
        }
        return nil
    }

    /// Build the chapter-thumbnail URL using Jellyfin's
    /// `/Items/{id}/Images/Chapter/{index}` endpoint. Returns nil
    /// when the chapter has no `imageTag`, the dropdown then falls
    /// back to its compact text-only row layout.
    private func chapterThumbnailURL(for index: Int) -> URL? {
        guard let baseURL = viewModel.playbackService.baseURL,
              viewModel.chapters.indices.contains(index),
              let tag = viewModel.chapters[index].imageTag
        else { return nil }
        return URL(string: "\(baseURL)/Items/\(viewModel.item.id)/Images/Chapter/\(index)?tag=\(tag)&maxWidth=480&quality=80")
    }

    private var controlsOverlay: some View {
        ZStack {
            VStack {
                Spacer()
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 300)
            }
            .ignoresSafeArea()

            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 200)
                Spacer()
            }
            .ignoresSafeArea()

            // Title (top left). HDR + Speed indicators live in a
            // separate always-visible column so the speed badge can
            // persist after the transport hides.
            VStack {
                HStack(alignment: .top) {
                    PlayerTitleOverlay(item: viewModel.item)
                    Spacer()
                }
                Spacer()
            }

            VStack {
                Spacer()
                TransportBar(
                    progress: viewModel.displayedProgress,
                    currentTime: viewModel.currentTime,
                    remainingTime: viewModel.remainingTime,
                    isScrubbing: viewModel.isScrubbing,
                    scrubTime: viewModel.scrubTime,
                    audioTracks: viewModel.player.audioTracks,
                    subtitleStreams: viewModel.subtitleStreams,
                    activeAudioIndex: viewModel.activeAudioIndex,
                    activeSubtitleIndex: viewModel.activeSubtitleIndex,
                    activeSpeedIndex: viewModel.activeSpeedIndex,
                    controlsFocus: viewModel.controlsFocus,
                    trackDropdown: viewModel.trackDropdown,
                    showSkipIntroButton: viewModel.isInsideIntro,
                    seasonEpisodes: viewModel.seasonEpisodes,
                    activeEpisodeID: viewModel.item.id,
                    episodeImageURL: { episodeThumbnailURL(for: $0) },
                    chapters: viewModel.chapters,
                    durationSeconds: viewModel.player.duration,
                    chapterImageURL: { chapterThumbnailURL(for: $0) },
                    pictureMode: viewModel.pictureMode,
                    showsInfoButton: viewModel.preferences.showStatsForNerds,
                    isStatsOverlayOpen: viewModel.showStatsOverlay
                )
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Top-Right Info Column

private extension PlayerOverlayView {
    /// Stack of informational badges in the top-right corner. The
    /// HDR badge follows the transport's visibility (Apple TV's own
    /// player does the same, informational, not action-required),
    /// while the speed badge is persistent whenever the rate isn't
    /// 1.0× so a user who set 1.5× and then hid the transport doesn't
    /// silently keep watching at the wrong speed.
    var topRightInfoColumn: some View {
        VStack {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    if viewModel.showControls && viewModel.videoFormat != .sdr {
                        VideoFormatBadge(format: viewModel.videoFormat)
                    }
                    // Index 2 is 1.0×, the picker default. Anything
                    // else (0.5/0.75/1.25/1.5/2.0) flips the badge on.
                    if viewModel.activeSpeedIndex != 2 {
                        SpeedBadge(index: viewModel.activeSpeedIndex)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 68)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.activeSpeedIndex)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showControls)
        .animation(.easeInOut(duration: 0.2), value: viewModel.videoFormat)
        .allowsHitTesting(false)
    }
}

// MARK: - Speed Badge

private struct SpeedBadge: View {
    let index: Int

    var body: some View {
        Text(TransportBar.speedLabel(for: index))
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }
}

// MARK: - Video Format Badge

private struct VideoFormatBadge: View {
    let format: VideoFormat

    var body: some View {
        Text(label)
            .font(.system(size: 18, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            )
    }

    private var label: String {
        switch format {
        case .sdr:          return "SDR"
        case .hdr10:        return "HDR10"
        case .hdr10Plus:    return "HDR10+"
        case .dolbyVision:  return "Dolby Vision"
        case .hlg:          return "HLG"
        }
    }
}

// MARK: - Diagnostic Log Overlay

/// Top-left diagnostic HUD that mirrors the engine's recent
/// `print(...)` lines into the player UI. Only mounted in DEBUG /
/// TestFlight builds (gated by `LogTap.isDiagnosticBuild`). Lets a
/// beta tester screenshot what the engine reported (DV detection,
/// HDR10+ extraction, format upgrades, etc.) without pairing the
/// Apple TV to a Mac for Console.app.
private struct DiagnosticLogOverlay: View {
    @ObservedObject private var tap = LogTap.shared

    /// Number of overlay rows rendered at once. 50 lines at the
    /// current 16 pt monospaced row height fills roughly the top
    /// 2/3 of a 1080p screen, which is what we want during
    /// diagnostic-build investigation sessions: enough vertical
    /// real estate to keep the full session preamble (engine
    /// init.mp4 box summary, HLS server setup, asset.load probes)
    /// AND the eventual AVPlayer failure landing on screen
    /// simultaneously. The overlay only renders in
    /// LogTap.isDiagnosticBuild (DEBUG + TestFlight), so the
    /// occlusion never hits an App Store user.
    private let visibleCount = 50

    var body: some View {
        VStack {
            // Full-width container so long diagnostic lines
            // (per-packet failure dumps, init.mp4 box summaries,
            // FFmpeg packet rescale traces) don't get truncated by
            // the row's lineLimit(1). The previous bounded box
            // truncated DrHurt's seg4 failure right before tb_out,
            // hiding the field we actually needed to read. Side
            // padding (60 left, 80 right) matches the player's
            // safe-area gutters; nothing else uses the top-left
            // quadrant when the overlay is visible.
            VStack(alignment: .leading, spacing: 2) {
                let visible = Array(tap.lines.suffix(visibleCount))
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 16, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.black.opacity(0.55))
            )
            .padding(.leading, 60)
            .padding(.trailing, 80)
            .padding(.top, 60)
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
