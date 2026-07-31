import AVFoundation
import UIKit
import SwiftUI

/// Owns the app's window on a wired external display: AVPlayer's video plus the subtitle overlay drawn
/// on top (Sodalite#98).
///
/// The transparent-overlay-over-AVKit design this replaces could not work. AVKit's external playback
/// (`usesExternalPlaybackWhileExternalScreenIsActive`) and an app window on the external screen are
/// mutually exclusive modes for one display: while AVKit owns it, nothing but the video is visible
/// there, and the moment the app puts a window on the scene AVKit stops driving the display. So drawing
/// subtitles out there means owning the video too.
///
/// The handover is fail-safe. Releasing AVKit's external playback and getting a picture into our own
/// layer cannot be verified without a wired display, so a watchdog waits for the first frame and, if it
/// does not arrive, hands the screen straight back to AVKit and latches off for the session. The worst
/// case is a brief flicker and the pre-existing behavior (video on the display, subtitles on the phone).
@MainActor
final class ExternalSubtitleWindowController {
    /// From releasing AVKit's external playback to a first frame in our own layer. Covers AVKit letting
    /// the display go, the scene arriving, and the layer's first decode; beyond it the takeover is treated
    /// as failed. Generous on purpose: the display shows the mirrored device in the meantime, so a long
    /// window costs an odd-looking second, while a short one would abort a slow-but-working handover.
    private static let handoverTimeout: Duration = .seconds(5)

    /// Latched when a takeover produced no picture. Binary rather than a retry timer: a flapping screen
    /// owner is worse than the limitation it works around. Cleared on the next player bind.
    private(set) var handoverFailed = false

    /// True once our layer has a picture on the external screen. The device keeps its own picture in
    /// AVKit's layer (simulator-verified: two layers on one player both render), so the on-frame overlay
    /// stays as it is and both screens show subtitles.
    private(set) var isShowingVideo = false

    private var window: UIWindow?
    private var root: ExternalVideoWindowRoot?
    private var releasedPlayer: AVPlayer?
    private var readinessObservation: NSKeyValueObservation?
    private var watchdog: Task<Void, Never>?

    /// The window scene of a connected wired external display, if any. On wired HDMI the system vends a
    /// scene with the non-interactive external-display role (simulator-verified on iOS 26.5 with no scene
    /// manifest in the bundle); AirPlay video and PiP do not, which is the wired-HDMI-only discriminator.
    /// Nil while AVKit's external playback owns the display, which is why the caller's "attached" signal
    /// cannot be this alone.
    static func currentExternalScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowExternalDisplayNonInteractive }
    }

    /// Every connected scene's role, for the decision log: distinguishes "no external display attached"
    /// from "attached but the app was never handed a scene for it".
    static func connectedSceneRoles() -> String {
        UIApplication.shared.connectedScenes
            .map { $0.session.role.rawValue.replacingOccurrences(of: "UIWindowSceneSessionRole", with: "") }
            .sorted()
            .joined(separator: ",")
    }

    func update(shouldOwnExternalScreen: Bool, player: AVPlayer?, viewModel: PlayerViewModel) {
        guard shouldOwnExternalScreen, let player else {
            tearDown()
            return
        }
        releaseExternalPlayback(on: player)
        guard let scene = Self.currentExternalScene() else {
            // AVKit was driving the display; its scene arrives on the next connect notification, which
            // calls back in here. The watchdog armed above bounds the wait.
            LogTap.shared.note("[ExternalSubs] released AVKit external playback, waiting for the display's scene")
            return
        }
        showWindow(on: scene, player: player, viewModel: viewModel)
    }

    /// Player rebind (next episode, audio switch): a fresh session gets a fresh attempt.
    func resetForNewPlayer() {
        handoverFailed = false
    }

    func tearDown() {
        watchdog?.cancel()
        watchdog = nil
        readinessObservation?.invalidate()
        readinessObservation = nil
        isShowingVideo = false
        if window != nil {
            root?.detachPlayer()
            window?.isHidden = true
            window?.rootViewController = nil
            window = nil
            root = nil
            LogTap.shared.note("[ExternalSubs] window torn down")
        }
        restoreExternalPlayback()
    }

    // MARK: - Screen ownership

    /// True while AVKit's external playback is released in our favour. The bind path reads it so a
    /// mid-session reload does not hand the screen back to AVKit under our own window.
    var ownsExternalScreen: Bool { releasedPlayer != nil }

    private func releaseExternalPlayback(on player: AVPlayer) {
        guard releasedPlayer !== player else { return }
        restoreExternalPlayback() // a rebuilt player: give the previous instance its screen back first
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        releasedPlayer = player
        LogTap.shared.note("[ExternalSubs] taking the external screen from AVKit")
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.handoverTimeout)
            guard !Task.isCancelled else { return }
            self?.failHandover()
        }
    }

    private func restoreExternalPlayback() {
        guard let player = releasedPlayer else { return }
        releasedPlayer = nil
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
    }

    private func failHandover() {
        guard !isShowingVideo else { return }
        handoverFailed = true
        LogTap.shared.note("[ExternalSubs] no picture within \(Self.handoverTimeout); handing the screen back to AVKit")
        tearDown()
    }

    // MARK: - Window

    private func showWindow(on scene: UIWindowScene, player: AVPlayer, viewModel: PlayerViewModel) {
        // Already up on this scene for this player; a rebuilt player needs a fresh layer.
        if let window, window.windowScene === scene, root?.playerLayer.player === player { return }
        readinessObservation?.invalidate()
        root?.detachPlayer()
        window?.isHidden = true
        let root = ExternalVideoWindowRoot(player: player, viewModel: viewModel)
        let newWindow = UIWindow(windowScene: scene)
        newWindow.backgroundColor = .black
        newWindow.isUserInteractionEnabled = false
        newWindow.rootViewController = root
        newWindow.isHidden = false
        window = newWindow
        self.root = root
        readinessObservation = root.playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) {
            [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            Task { @MainActor [weak self] in self?.handoverSucceeded() }
        }
        LogTap.shared.note("[ExternalSubs] window up on external scene \(scene.effectiveGeometry.coordinateSpace.bounds.size)")
    }

    private func handoverSucceeded() {
        guard !isShowingVideo else { return }
        isShowingVideo = true
        watchdog?.cancel()
        watchdog = nil
        LogTap.shared.note("[ExternalSubs] first frame on the external screen; app owns the display")
    }
}

/// Root of the external-display window: AVPlayer's video under the same subtitle overlay the phone
/// draws. Non-interactive, so it carries no controls.
@MainActor
private final class ExternalVideoWindowRoot: UIViewController {
    let playerLayer: AVPlayerLayer
    private let subtitles: UIHostingController<ExternalSubtitleView>

    init(player: AVPlayer, viewModel: PlayerViewModel) {
        playerLayer = AVPlayerLayer(player: player)
        subtitles = UIHostingController(rootView: ExternalSubtitleView(viewModel: viewModel))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        view.layer.addSublayer(playerLayer)
        addChild(subtitles)
        subtitles.view.backgroundColor = .clear
        subtitles.view.frame = view.bounds
        subtitles.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(subtitles.view)
        subtitles.didMove(toParent: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Implicit animation on a bounds change would slide the video across the screen on rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = view.bounds
        CATransaction.commit()
    }

    /// Drop the player before the window goes away so AVKit's own layer can take the video back.
    func detachPlayer() {
        playerLayer.player = nil
        playerLayer.removeFromSuperlayer()
    }
}
