import SwiftUI
import AetherEngine
import AVFoundation
import AVKit
import Combine

// MARK: - Player View Controller

/// Full-screen video player that handles ALL Siri Remote input.
///
/// `showsPlaybackControls = true` is REQUIRED on tvOS to activate AVKit's internal Now Playing
/// session + AirPods detection + Atmos sync; all visible chrome is suppressed but the transport bar
/// flag stays ON so AVKit routes iPhone Control Center skip events into our delegate and keeps its
/// play/pause handler live (engine reconciles `state` from `timeControlStatus`, else rapid presses
/// get swallowed). Now Playing surfaces via AVKit reading `AVPlayerItem.externalMetadata`.
/// Failed alternatives: `showsPlaybackControls = false` killed the auto-session (c22b295); explicit
/// `MPNowPlayingSession(players:)` conflicted with AVKit's (CoreMediaErrorDomain -16046, d30bace);
/// manual `MPNowPlayingInfoCenter` writes tripped `_dispatch_assert_queue_fail`.
/// Presented via UIKit `present(_:animated:)` NOT SwiftUI fullScreenCover, which would steal Menu.
@MainActor
final class PlayerHostController: AVPlayerViewController {
    /// `internal` (not `private`) so cross-file extensions (PlayerHostController+SkipDelegate) can reach it.
    let viewModel: PlayerViewModel
    private let tintColor: Color?
    private let onDismiss: () -> Void

    private var hasLaunched = false

    /// Engine render surface, mounted into `contentOverlayView` only for the SW (dav1d) backend; the native path renders off `self.player`'s own AVPlayerLayer.
    private let aetherView = AetherPlayerView()
    private var aetherViewMounted = false

    /// Our recognizers, so suppressAVKitGestures can disable AVKit's own (arrow→10s skip, select→toggle, pan→scrub) which otherwise fire silently and eat presses before our handlers.
    private var ourGestureRecognizers: [UIGestureRecognizer] = []

    /// Weak ref to our overlay's hosting view so suppressAVKitChrome's class-name heuristic skips it (it sits among AVKit's chrome views).
    private weak var overlayHostingView: UIView?

    /// Engine `$currentAVPlayer` (fires on every internal reload, e.g. selectAudioTrack rebuilds NativeAVPlayerHost; sink rebinds `.player`) + `$playbackBackend` (mounts aetherView for SW path).
    private var engineSubscriptions: Set<AnyCancellable> = []

    /// Diagnostic KVO on the AVPlayerLayer AVKit actually renders with; the engine's NativeAVPlayerHost.playerLayer is detached on the native path, so only THIS layer's first-frame readiness is authoritative for the audio-before-video gap.
    private var avkitLayerObservation: NSKeyValueObservation?
    /// 1 Hz startup sampler for the audio-before-video diagnosis: isReadyForDisplay can be true seconds before audio yet show black (readiness != composition), so it also logs layer identity (AVKit may swap layers on rebind), videoRect, and clock for 30s.
    private var avkitLayerSampler: Task<Void, Never>?

    /// True only between `didEnterBackground` and the next `didBecomeActive`; the app switcher (double Home) fires only willResignActive, so this stays false and we skip the reload-and-pause routine for it.
    private var wasFullyBackgrounded = false
    /// Set synchronously by the AVKit PiP delegate (willStart) BEFORE PiP dismisses this VC, so
    /// viewWillDisappear can tell a PiP handoff from a real dismiss and not stopPlayback (which would
    /// idle the engine and immediately close PiP). nonisolated(unsafe): written from the nonisolated
    /// delegate + read on MainActor, both on the main thread in practice (iOS only).
    nonisolated(unsafe) var pipActive = false

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

        // REQUIRED on tvOS for AVKit's Now Playing session + AirPods + Atmos sync; visible chrome is suppressed separately.
        showsPlaybackControls = true
        // Kept ON so AVKit dispatches iPhone Control Center 10s skip events into our delegate (timeToSeekAfterUserNavigatedFrom / skipToNextItem); without it the press lands nowhere. Our overlay covers the visible bar.
        #if os(tvOS)
        playbackControlsIncludeTransportBar = true
        playbackControlsIncludeInfoViews = false
        #endif
        // Engine is sole display-criteria writer (LoadOptions.suppressDisplayCriteria = false in PlayerViewModel); AVKit-auto would race the engine pre-flight apply() + waitForSwitch, and on tvOS 26.5+ the HLS variant validator rejects items at playlist-parse if no criteria are active for the master's VIDEO-RANGE (item.failed -11868). Tech Talk 503: criteria first, THEN AVPlayerItem. Don't flip to true without also flipping suppressDisplayCriteria, or dual writers bring back late re-negotiate (DrHurt Build 170).
        #if os(tvOS)
        appliesPreferredDisplayCriteriaAutomatically = false
        contextualActions = []
        #endif
        // iOS uses AVKit-native PiP backed by the engine's background keepalive (AetherEngine
        // backgroundPlaybackEnabled + pictureInPictureActive): allowsPictureInPicturePlayback keeps the
        // player alive across backgrounding, canStartPictureInPictureAutomaticallyFromInline triggers PiP
        // on swipe-Home. tvOS does not use PiP.
        #if os(iOS)
        allowsPictureInPicturePlayback = true
        canStartPictureInPictureAutomaticallyFromInline = true
        #else
        allowsPictureInPicturePlayback = false
        #endif

        // .skipItem routes AVKit skip events to delegate skipToNextItem/skipToPreviousItem instead of the default 10s seek (a no-op without track listings).
        #if os(tvOS)
        skippingBehavior = .skipItem
        #endif
        delegate = self

        // The nil case is load-bearing: the SW (dav1d/VP9) path never sets currentAVPlayer, so without `self.player = nil` AVKit keeps the old item-less player and renders its own spinner over our frames ("AV1 plays but loading never goes away").
        let engine = viewModel.player
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let self else { return }
                LogTap.shared.note("[NowPlaying] vc_rebind player=\(avPlayer == nil ? "nil" : "set") items=\(avPlayer?.currentItem?.externalMetadata.count ?? -1)")
                if let avPlayer {
                    // AirPlay enabled: the engine serves the loopback HLS over the LAN WiFi IP while external
                    // playback is active (AetherEngine #86), so the receiver reaches the engine-processed stream
                    // (DV/Atmos/subtitles preserved). Local playback stays on 127.0.0.1.
                    avPlayer.allowsExternalPlayback = true
                    // iOS wired HDMI (Sodalite#34): while a mirrored external screen is active AVPlayer stays in the
                    // small mirror window unless this is set, so the video renders in "Mirror Mode" instead of filling
                    // the TV. Setting it makes AVPlayer switch to external playback (full-screen out) on connect. This
                    // also flips isExternalPlaybackActive, so the engine's #86 handler reloads onto the LAN IP + MEDIA
                    // playlist exactly like wireless AirPlay: harmless here (127.0.0.1 fallback if no WiFi) but it drops
                    // the DV/HDR master signaling, so DV over a wired adapter comes out through the MEDIA playlist.
                    #if os(iOS)
                    avPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
                    #endif
                    self.player = avPlayer
                    // Each `self.player` assignment resets videoGravity to .resizeAspect, so re-apply the user's picture-mode after every rebind or an audio-switch reload silently drops fill mode.
                    self.applyVideoGravity(for: self.viewModel.pictureMode)
                    self.observeAVKitRenderLayer(for: avPlayer)
                } else {
                    self.player = nil
                    self.avkitLayerObservation?.invalidate()
                    self.avkitLayerObservation = nil
                    self.avkitLayerSampler?.cancel()
                    self.avkitLayerSampler = nil
                }
            }
            .store(in: &engineSubscriptions)

        // Applied to AVPlayerViewController directly because AVKit's internal layer renders the native path; engine.videoGravity's layer is never mounted here.
        viewModel.onPictureModeChanged = { [weak self] mode in
            self?.applyVideoGravity(for: mode)
        }
        // Seed initial gravity: applyPictureMode may have fired before the callback was wired, else AVKit stays at default .resizeAspect.
        applyVideoGravity(for: viewModel.pictureMode)

        engine.$playbackBackend
            .receive(on: DispatchQueue.main)
            .sink { [weak self] backend in
                guard let self else { return }
                switch backend {
                case .software, .aether:
                    self.mountAetherViewIfNeeded()
                case .native, .none, .audio:
                    // .audio is the audio-only path: no video surface to mount.
                    self.unmountAetherViewIfNeeded()
                }
            }
            .store(in: &engineSubscriptions)

        // End-of-content auto-dismiss: natural end-of-stream (state .idle after hasStartedPlaying, no next episode) leaves a black no-focus screen; route through dismissPlayer. Error paths take state .error (own overlay) and never reach here.
        viewModel.onPlaybackReachedEnd = { [weak self] in
            Task { @MainActor in
                self?.dismissPlayer()
            }
        }

        // `.tint(...)` must be applied here: the UIKit modal never inherits SodaliteApp's WindowGroup tint.
        let overlay = PlayerOverlayView(
            viewModel: viewModel,
            onDismiss: { [weak self] in self?.dismissPlayer() },
            tintColor: tintColor
        )
            .tint(tintColor)
        let hosting = UIHostingController(rootView: overlay)
        hosting.view.backgroundColor = .clear
        #if os(iOS)
        // iOS controls (buttons, scrubber) are SwiftUI-interactive; empty overlay regions pass touches
        // through to the host's screen gestures. tvOS stays display-only (the press machine drives input).
        hosting.view.isUserInteractionEnabled = true
        #else
        hosting.view.isUserInteractionEnabled = false
        #endif
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)
        overlayHostingView = hosting.view

        #if os(tvOS)
        // Siri Remote input. iOS touch transport is wired in Phase 3.
        // Short Select activates; held Select deletes the highlighted external subtitle (Feature #4). tap require(toFail:) hold so a quick click never deletes.
        let selectTap = addPressGesture(.select, action: #selector(selectPressed))
        let selectHold = addHoldGesture(.select, action: #selector(selectHeld(_:)))
        selectTap.require(toFail: selectHold)
        addPressGesture(.playPause, action: #selector(playPausePressed))
        addPressGesture(.menu, action: #selector(menuPressed))
        // left/right: short click = discrete skip, held = continuous spool (hold-to-seek). tap require(toFail:) hold so a quick click never spools.
        let leftTap = addPressGesture(.leftArrow, action: #selector(leftPressed))
        let leftHold = addHoldGesture(.leftArrow, action: #selector(leftHeld(_:)))
        leftTap.require(toFail: leftHold)
        let rightTap = addPressGesture(.rightArrow, action: #selector(rightPressed))
        let rightHold = addHoldGesture(.rightArrow, action: #selector(rightHeld(_:)))
        rightTap.require(toFail: rightHold)
        addPressGesture(.upArrow, action: #selector(upPressed))
        addPressGesture(.downArrow, action: #selector(downPressed))

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
        ourGestureRecognizers.append(pan)
        #else
        // iOS touch transport: screen gestures live in the SwiftUI overlay (PlayerGestureCatcher),
        // below the controls, so they coexist with the tappable widgets. Nothing to attach here.
        #endif

        // Foreground reloads the pipeline at current position (VT + AVIO die in suspension).
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
        // didEnterBackground fires only for a real background trip (Home/sleep/screensaver), not the app switcher.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    /// Apply picture-mode as videoGravity directly on this AVPlayerViewController, the surface AVKit renders the native path with (engine.nativeHost.playerLayer is unmounted here).
    private func applyVideoGravity(for mode: PlaybackPreferences.PictureMode) {
        switch mode {
        case .original: self.videoGravity = .resizeAspect
        case .fill:     self.videoGravity = .resizeAspectFill
        }
    }

    /// Mount aetherView in AVKit's contentOverlayView for the SW (dav1d) path. Idempotent. contentOverlayView sits between AVKit's player layer and chrome, so engine frames render above the empty player surface and below our overlay.
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

    /// Audio-before-video diagnostic: KVO `isReadyForDisplay` on the AVPlayerLayer bound to `avPlayer` (walked from the tree; AVKit creates it async after `self.player`, so retry). Diff against engine `timeControlStatus=playing` stamps = black-screen-with-audio window.
    private func observeAVKitRenderLayer(for avPlayer: AVPlayer, attempt: Int = 0) {
        avkitLayerObservation?.invalidate()
        avkitLayerObservation = nil

        func findLayer(_ layer: CALayer) -> AVPlayerLayer? {
            if let pl = layer as? AVPlayerLayer, pl.player === avPlayer { return pl }
            for sub in layer.sublayers ?? [] {
                if let hit = findLayer(sub) { return hit }
            }
            return nil
        }

        guard let root = viewIfLoaded?.layer, let layer = findLayer(root) else {
            guard attempt < 20 else {
                LogTap.shared.note("[AVKitLayer] render layer NOT found after \(attempt) attempts")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.player === avPlayer else { return }
                self.observeAVKitRenderLayer(for: avPlayer, attempt: attempt + 1)
            }
            return
        }

        let attachedAt = Date()
        LogTap.shared.note("[AVKitLayer] observing render layer (found on attempt \(attempt), ready=\(layer.isReadyForDisplay))")
        avkitLayerObservation = layer.observe(
            \.isReadyForDisplay, options: [.new, .initial]
        ) { layer, change in
            let elapsed = Date().timeIntervalSince(attachedAt)
            LogTap.shared.note(
                "[AVKitLayer] isReadyForDisplay=\(change.newValue ?? layer.isReadyForDisplay) t+\(String(format: "%.2f", elapsed))s after attach"
            )
        }

        avkitLayerSampler?.cancel()
        avkitLayerSampler = Task { @MainActor [weak self] in
            // Sample 1 Hz for 30s, emit only on state change (ready, videoRect, tcs, clock advancing) so steady-state repeats don't flood the log.
            var lastSignature: String?
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, self.player === avPlayer else { return }
                let stamp = String(format: "%.0f", Date().timeIntervalSince(attachedAt))
                // Re-find each tick: AVKit may have swapped its internal layer (identity in log exposes it).
                guard let root = self.viewIfLoaded?.layer,
                      let current = findLayer(root) else {
                    let sig = "GONE"
                    if sig != lastSignature {
                        lastSignature = sig
                        LogTap.shared.note("[AVKitLayer] sample t+\(stamp)s: layer GONE")
                    }
                    continue
                }
                let r = current.videoRect
                let t = avPlayer.currentTime().seconds
                let tcs = avPlayer.timeControlStatus.rawValue
                // Quantize clock to "is it advancing" (whole seconds) so a normal tick isn't a change every sample but a stall collapses to one signature.
                let clockBucket = t.isFinite ? Int(t) : -1
                let sig = "\(ObjectIdentifier(current))|\(current.isReadyForDisplay)|\(Int(r.width))x\(Int(r.height))|\(tcs)|\(clockBucket > 0)"
                guard sig != lastSignature else { continue }
                lastSignature = sig
                LogTap.shared.note(
                    "[AVKitLayer] sample t+\(stamp)s layer=\(String(UInt(bitPattern: ObjectIdentifier(current).hashValue), radix: 16)) "
                    + "ready=\(current.isReadyForDisplay) videoRect=\(Int(r.width))x\(Int(r.height)) "
                    // -1.0, not -1: with CVarArg as the contextual type the
                    // ternary's branches coerce independently, so a bare -1
                    // becomes Int and mismatches "%.2f" at runtime (fired
                    // exactly when the clock went nan during a live stall).
                    + "clock=\(String(format: "%.2f", t.isFinite ? t : -1.0)) tcs=\(tcs)"
                )
            }
        }
    }

    #if os(iOS)
    // The session mask applies only while a lock is engaged (during playback); when released for
    // dismiss it widens to allButUpsideDown so the dismiss transition shares a common orientation
    // with the portrait app and can rotate back instead of stalling on a black frame. Follow mode
    // (mask nil) rotates freely the whole session. iPad allows all.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return PlayerOrientation.playerMask ?? .allButUpsideDown
    }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        PlayerOrientation.presentationOrientation
    }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    #endif

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        #if os(iOS)
        PlayerOrientation.engage(locked: viewModel.preferences.playerRotationLocked)
        viewModel.startVolumeObservation()
        #endif
        // Kick off playback as the modal starts appearing so network/demuxer work overlaps the present-then-layout sequence.
        guard !hasLaunched else { return }
        hasLaunched = true
        // Tracked launch: a back-press during loading cancels this task (latches teardown) so an in-flight load can't resume into player.load() after dismissal and leave audio behind a gone player.
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

    @discardableResult
    private func addHoldGesture(_ type: UIPress.PressType, action: Selector) -> UILongPressGestureRecognizer {
        let hold = UILongPressGestureRecognizer(target: self, action: action)
        hold.allowedPressTypes = [NSNumber(value: type.rawValue)]
        hold.minimumPressDuration = 0.35
        view.addGestureRecognizer(hold)
        ourGestureRecognizers.append(hold)
        return hold
    }

    /// Disable every AVKit-owned recognizer (arrow→10s skip, pan→scrub, select→toggle) except ours; without this the hidden chrome's gestures still fire and eat presses. Idempotent.
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

    /// alpha=0 AVKit's chrome views (kept rendered because the transport-bar flag is needed for CC skips). The skip handler lives on AVPlayerViewController, not the chrome, so hiding optically doesn't break it. Class-name matching is runtime introspection (not private-API dispatch), App Store review allows it.
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
        // Keywords matched against AVKit's runtime view hierarchy: Controls (_AVPlayerControlsView), Transport (scrubber), Info (title/_AVPlayerInfoView), Menu (AVInfoMenuCell picker rows), Focus (_AVFocusContainerView). Match Focus not Container (too broad).
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
        // AVKit re-attaches recognizers and fades chrome back in on layout passes; re-suppress every pass.
        suppressAVKitGestures()
        suppressAVKitChrome()
        // Re-pin the overlay to the final bounds: autoresizing alone can inherit a transitional size
        // when the modal presents mid-rotation (follow-rotation mode presents in whatever orientation
        // the user holds), leaving the controls a few points wider than the screen in portrait.
        if let host = overlayHostingView, host.frame != view.bounds {
            host.frame = view.bounds
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // HDR/SDR display-mode switches fire viewWillDisappear without dismissing; only stop playback on a real dismiss.
        // PiP also dismisses this VC on start (isBeingDismissed) but playback must continue in the PiP window,
        // so skip the stop while PiP is active (else the engine idles and PiP closes instantly).
        guard (isBeingDismissed || isMovingFromParent), !pipActive else { return }
        #if os(iOS)
        PlayerOrientation.unlock()
        #endif
        unmountAetherViewIfNeeded()
        player = nil
        viewModel.stopPlayback()
    }

    @objc private func appDidEnterBackground() {
        wasFullyBackgrounded = true
    }

    @objc private func appDidBecomeActive() {
        guard viewModel.hasStartedPlaying else { return }

        // App switcher lands here without didEnterBackground; decoders + audio are still alive, so nothing to rebuild.
        guard wasFullyBackgrounded else { return }
        wasFullyBackgrounded = false

        #if os(iOS)
        // Background playback (PiP / background audio) kept the pipeline alive + playing, so there is nothing
        // to reload and we must NOT force it paused (it should keep playing on return). Only the torn-down
        // path (background disabled, or paused-in-background teardown -> .paused/.idle) needs the reload below.
        if viewModel.player.state == .playing { return }
        #endif

        // tvOS deactivates the AVAudioSession on background; without re-arming it the post-reload resume drives a synchronizer with no live session (state .playing but no audio, no frames advance).
        try? AVAudioSession.sharedInstance().setActive(true)

        // Real background return: VT + AVIO are dead, reload from current position then hold paused on the resumed frame (auto-resume after a sleep gap is startling). load() returns once the panel handshake settles, NOT once audio flows, so the trailing pause can land while AVPlayer is still waitingToPlayAtSpecifiedRate re-buffering the AVIO reconnect. If the user presses Play during the slow reload that intent must win or it clobbers the resume ("play does nothing, press again"); beginBackgroundReload/finishBackgroundReload arbitrate.
        viewModel.beginBackgroundReload()
        Task { @MainActor in
            try? await viewModel.player.reloadAtCurrentPosition()
            viewModel.finishBackgroundReload()
        }
    }

    // MARK: - Press Handlers (state machine)

    /// Stats panel captures every press while mounted (not SwiftUI-focusable; our @objc gestures sit between SwiftUI and the remote) so nav is routed at the press-handler level: up/down scroll, select/menu dismiss, left/right inert.
    private var statsOverlayCapturesPresses: Bool {
        viewModel.showStatsOverlay
    }

    /// Indices into `PlayerViewModel.statsSectionAnchors` currently rendered, mirroring StatsOverlayView's @ViewBuilder gates: 0 live + 1 playback always; 2 video; 3 audio; 4 subtitle; 5 file; 6-8 engine diagnostics (showEngineDiagnostics). advanceStatsCursor steps only over these, else scrollTo no-ops and the cursor "sticks" (the "up doesn't work" repro).
    private var availableStatsSectionIndices: [Int] {
        var indices: [Int] = []
        indices.append(0)
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

    /// Step the stats cursor by `delta` through `availableStatsSectionIndices`, clamped. If current index dropped out (e.g. subtitles toggled while open), snap to the closest available index instead of sticking.
    private func advanceStatsCursor(by delta: Int) {
        let avail = availableStatsSectionIndices
        guard !avail.isEmpty else { return }
        let current = viewModel.statsSectionIndex
        let pos: Int
        if let exact = avail.firstIndex(of: current) {
            pos = exact
        } else {
            pos = avail.enumerated().min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 0
        }
        let newPos = max(0, min(avail.count - 1, pos + delta))
        viewModel.statsSectionIndex = avail[newPos]
    }

    @objc private func selectPressed() {
        if viewModel.isSubtitleDeletePromptVisible { viewModel.subtitleDeletePromptConfirm(); return }
        if viewModel.subtitleSearchVisible { viewModel.subtitleSearchConfirm(); return }
        // Stats panel open: Select closes it (like Menu); the transport chip still toggles only when closed.
        if statsOverlayCapturesPresses {
            viewModel.showStatsOverlay = false
            return
        }
        // Skip Intro over a transient scrub: the touchpad reports a tiny pan before its click, past the 40pt threshold, flipping isScrubbing/showControls; without this the tap-to-skip lands in commit-scrub. scrubMovedMeaningfully separates a deliberate drag (which must commit to its target) from the pre-click jitter, so only jitter skips here.
        if viewModel.isInsideIntro && !viewModel.isDropdownOpen
           && (!viewModel.showControls || viewModel.controlsFocus == .progressBar)
           && !viewModel.scrubMovedMeaningfully {
            if viewModel.isScrubbing { viewModel.cancelScrub() }
            viewModel.skipIntro()
            return
        }

        // Next-episode commandeers Select only when transport is hidden, else a surprise next would clobber an active interaction.
        if !viewModel.showControls && !viewModel.isDropdownOpen {
            if viewModel.showNextEpisodeOverlay {
                Task { await viewModel.playNextEpisode() }
                return
            }
        }
        if viewModel.isDropdownOpen {
            viewModel.confirmDropdownSelection()
        } else if viewModel.showControls && viewModel.controlsFocus != .progressBar {
            viewModel.activateControl(viewModel.controlsFocus)
        } else if viewModel.isScrubbing {
            viewModel.commitScrub()
        } else if viewModel.showControls {
            viewModel.togglePlayPause()
        } else {
            viewModel.showControlsTemporarily()
        }
    }

    @objc private func playPausePressed() {
        if viewModel.isSubtitleDeletePromptVisible { return }
        if viewModel.subtitleSearchVisible { return }
        viewModel.togglePlayPause()
    }

    @objc private func menuPressed() {
        if viewModel.isSubtitleDeletePromptVisible { viewModel.subtitleDeletePromptDismiss(); return }
        if viewModel.subtitleSearchVisible {
            viewModel.dismissSubtitleSearch()
            viewModel.scheduleControlsHide()
            return
        }
        // Cancel next-episode countdown only hijacks Menu when transport is hidden; with controls open Menu behaves normally and the countdown keeps running.
        if viewModel.showNextEpisodeOverlay && !viewModel.showControls && !viewModel.isDropdownOpen {
            viewModel.cancelNextEpisode()
            return
        }
        // Stats panel intercepts Menu when it's the only thing open: close it, don't exit the player.
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
        if viewModel.isSubtitleDeletePromptVisible { viewModel.subtitleDeletePromptToggleFocus(); return }
        if viewModel.subtitleSearchVisible { viewModel.subtitleSearchMoveLeft(); return }
        // Stats panel: horizontal nav is inert (no rows behind it to target).
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
        if viewModel.isSubtitleDeletePromptVisible { viewModel.subtitleDeletePromptToggleFocus(); return }
        if viewModel.subtitleSearchVisible { viewModel.subtitleSearchMoveRight(); return }
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

    /// Hold Select on an external subtitle row to delete it (Feature #4); ignored for embedded tracks, Off/Search rows, other dropdowns.
    @objc private func selectHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        guard case .subtitle(let idx) = viewModel.trackDropdown else { return }
        let streams = viewModel.displaySubtitleStreams
        let streamIdx = idx - 2 // 0 = header, 1 = Off, 2...n+1 = streams, n+2 = Search
        guard streamIdx >= 0, streamIdx < streams.count,
              streams[streamIdx].isExternal == true else { return }
        viewModel.requestSubtitleDeletion(streamIndex: streams[streamIdx].index)
    }

    /// Continuous hold-to-seek spool from a directional long press; gated like the tap-skip path so a hold while navigating buttons or with stats/dropdown up is ignored.
    private func handleHold(_ gesture: UILongPressGestureRecognizer, direction: Int) {
        switch gesture.state {
        case .began:
            if statsOverlayCapturesPresses || viewModel.isDropdownOpen || viewModel.subtitleSearchVisible || viewModel.isSubtitleDeletePromptVisible { return }
            if viewModel.showControls && viewModel.controlsFocus != .progressBar { return }
            viewModel.beginContinuousSeek(direction: direction)
        case .ended, .cancelled, .failed:
            viewModel.endContinuousSeek()
        default:
            break
        }
    }

    /// Step focus through transport buttons, built dynamically so a stream missing audio/subtitle tracks has no dead stops.
    private func stepTransportFocus(direction: Int) {
        var order: [PlayerViewModel.ControlsFocus] = []
        if viewModel.isInsideIntro { order.append(.skipIntroButton) }
        if viewModel.seasonEpisodes.count > 1 { order.append(.episodeButton) }
        // Mirror TransportBar's chapter-button gate (hidden on series episodes), else focus lands on an unrendered button.
        if viewModel.chapters.count > 1, viewModel.seasonEpisodes.count <= 1 {
            order.append(.chapterButton)
        }
        if !viewModel.player.audioTracks.isEmpty { order.append(.audioButton) }
        if !viewModel.subtitleStreams.isEmpty || viewModel.supportsSubtitleSearch {
            order.append(.subtitleButton)
        }
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
        if viewModel.isSubtitleDeletePromptVisible { return }
        if viewModel.subtitleSearchVisible { viewModel.subtitleSearchMoveUp(); return }
        // Stats panel: step the section cursor (advanceStatsCursor skips unrendered anchors, see availableStatsSectionIndices).
        if statsOverlayCapturesPresses {
            advanceStatsCursor(by: -1)
            return
        }
        if viewModel.isDropdownOpen {
            moveDropdownHighlight(by: -1)
        } else if viewModel.showControls {
            switch viewModel.controlsFocus {
            case .progressBar:
                // Live: only control above the scrubber is the "Return to Live" pill (only when behind the edge); LiveTransportBar has no VOD buttons.
                if viewModel.isLiveSession {
                    if !viewModel.isAtLiveEdge {
                        viewModel.controlsFocus = .returnToLiveButton
                    }
                    viewModel.scheduleControlsHide()
                    break
                }
                let hasAudio = !viewModel.player.audioTracks.isEmpty
                let hasSubs = !viewModel.subtitleStreams.isEmpty || viewModel.supportsSubtitleSearch
                let hasEpisodes = viewModel.seasonEpisodes.count > 1
                // Mirror TransportBar gate: chapter button suppressed for series episodes.
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
        if viewModel.isSubtitleDeletePromptVisible { return }
        if viewModel.subtitleSearchVisible { viewModel.subtitleSearchMoveDown(); return }
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

    // MARK: - Dropdown highlight navigation (tvOS arrow presses)

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
            // header(Secondary) + Off + streams + Search online
            let count = viewModel.displaySubtitleStreams.count + 3
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .subtitle(highlighted: newIdx)
        case .secondarySubtitle(let idx):
            // Back + Off + candidate streams
            let count = viewModel.secondarySubtitleCandidates.count + 2
            guard count > 0 else { return }
            let newIdx = max(0, min(count - 1, idx + offset))
            viewModel.trackDropdown = .secondarySubtitle(highlighted: newIdx)
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

    private func dismissPlayer() {
        #if os(iOS)
        // Release the landscape lock first so the VC reports a portrait-compatible orientation for the
        // dismiss transition (else the rotation back can stall, leaving the video black + the modal up).
        PlayerOrientation.unlock()
        viewModel.stopVolumeObservation()
        #endif
        unmountAetherViewIfNeeded()
        player = nil
        // stopPlayback fire-and-forgets the reportStop call (DrHurt #12); called inline so synchronous teardown finishes before onDismiss and the back press hits the dismiss animation immediately.
        viewModel.stopPlayback()
        onDismiss()
        #if os(iOS)
        // Fallback: if the host-driven dismiss above did not take (a stale captured host reference left
        // the fullScreen modal up while only the stream stopped), dismiss self via its real presenter.
        if presentingViewController != nil { dismiss(animated: false) }
        #endif
    }

    // MARK: - Pan (Touchpad Scrubbing)

    private enum PanAxis { case undetermined, horizontal, vertical }

    private var lastDropdownStep: CGFloat = 0
    private var panAxis: PanAxis = .undetermined
    private var verticalStepFired = false
    private var horizontalStepFired = false
    private var scrubCommitted = false

    /// Travel (pt) to commit a pan to one axis; low enough to feel responsive, high enough a diagonal swipe doesn't trigger vertical nav.
    private static let panAxisCommitThreshold: CGFloat = 40
    /// Vertical travel (pt) to fire up/down, one fire per gesture (single-shot like arrow keys).
    private static let verticalFireThreshold: CGFloat = 150
    /// Horizontal travel (pt) to fire left/right for transport-button nav (not scrubbing).
    private static let horizontalFireThreshold: CGFloat = 150
    /// Min velocity (pt/s) for a step-firing pan to count as intentional; filters resting-finger drift that accumulates past the distance threshold and steals focus (real swipes are >1000 pt/s).
    private static let stepMinVelocity: CGFloat = 400
    /// Min velocity (pt/s) for a horizontal pan to commit to scrubbing; lower than stepMinVelocity so a slow deliberate drag still scrubs while resting-finger drift doesn't. Initial-commit gate only.
    private static let scrubCommitMinVelocity: CGFloat = 200
    /// Touchpad travel (pt) per dropdown item (cumulative-translation nav). Kept well above verticalFireThreshold (150) because indirect touches over-report translation, so a flick at 120pt jumped 3-4 rows.
    private static let dropdownStepSize: CGFloat = 300

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if viewModel.isSubtitleDeletePromptVisible { return }
        // Subtitle search overlay: swipes route through the arrow-key @objc handlers via the cumulative dropdownStepSize model (one step per item, no overshoot).
        if viewModel.subtitleSearchVisible {
            switch gesture.state {
            case .began:
                panAxis = .undetermined
                lastDropdownStep = 0
            case .changed:
                let t = gesture.translation(in: view)
                if panAxis == .undetermined {
                    let absX = abs(t.x)
                    let absY = abs(t.y)
                    if max(absX, absY) >= Self.panAxisCommitThreshold {
                        panAxis = absX > absY ? .horizontal : .vertical
                    }
                }
                guard panAxis != .undetermined else { break }
                let delta = panAxis == .horizontal ? t.x : t.y
                let currentStep = (delta / Self.dropdownStepSize).rounded(.towardZero)
                if currentStep != lastDropdownStep {
                    let steps = Int(currentStep - lastDropdownStep)
                    let forward = steps > 0
                    for _ in 0..<abs(steps) {
                        if panAxis == .horizontal {
                            forward ? rightPressed() : leftPressed()
                        } else {
                            forward ? downPressed() : upPressed()
                        }
                    }
                    lastDropdownStep = currentStep
                }
            case .ended, .cancelled:
                panAxis = .undetermined
                lastDropdownStep = 0
            default:
                break
            }
            return
        }
        // Stats overlay: vertical swipes step the section cursor, horizontal swipes are swallowed so they don't scrub behind the panel.
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
                // Horizontal axis swallowed: overlay has no left/right nav.
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
            // Vertical swipe navigates dropdown; cumulative translation / dropdownStepSize = items, prevents over-scroll on fast swipes.
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

        // Lock pan to a dominant axis. Vertical = arrow-key nav. Horizontal conditional: scrub when progress bar focused or controls hidden, else single-shot left/right between transport buttons.
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
                        // Zero out pre-commit drift so the first scrub frame starts at 0, not the sub-threshold offset.
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
            // Only finalise when actually scrubbing; horizontal-into-nav never touched the timeline.
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

