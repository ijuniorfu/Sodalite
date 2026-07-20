#if os(tvOS)
import AVKit
import UIKit

/// View whose backing layer IS an AVPlayerLayer, so bounds changes track autoresizing without manual layout.
final class PiPSourceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Host-built PiP for the tvOS player: AVKit exposes no API to trigger its own PiP from custom chrome,
/// so this owns an AVPictureInPictureController around a second full-size AVPlayerLayer that covers
/// AVKit's render layer with identical content (same AVPlayer, decode happens once).
@MainActor
final class PlayerPiPController: NSObject {
    let sourceView = PiPSourceView()

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?

    var onPossibleChanged: ((Bool) -> Void)?
    var onWillStart: (() -> Void)?
    var onDidStart: (() -> Void)?
    var onFailedToStart: ((Error) -> Void)?
    /// AVKit's restore completion MUST be answered exactly once; forwarded to the session coordinator.
    var onRestoreRequested: ((@escaping (Bool) -> Void) -> Void)?
    var onDidStop: (() -> Void)?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    /// (Re)binds the source layer to the engine's current AVPlayer; nil unbinds (SW path / teardown).
    /// Rebinding on the SAME controller keeps an active PiP window across engine reloads (audio switch,
    /// next episode); whether the window survives the player swap is a device-verify item.
    func bind(player: AVPlayer?) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        sourceView.playerLayer.player = player
        guard player != nil else {
            // An engine reload publishes a nil gap (stopInternal) before the fresh player arrives; tearing
            // the controller down here would close an open PiP window mid next-episode/audio-switch. Keep
            // it while the window is up, the fresh bind re-attaches the layer's player.
            if !isActive {
                possibleObservation?.invalidate()
                possibleObservation = nil
                controller = nil
            }
            onPossibleChanged?(false)
            return
        }
        guard controller == nil else { return }
        guard let pip = AVPictureInPictureController(playerLayer: sourceView.playerLayer) else {
            LogTap.shared.note("[PiP] controller init failed (layer rejected)")
            return
        }
        pip.delegate = self
        controller = pip
        possibleObservation = pip.observe(\.isPictureInPicturePossible, options: [.new, .initial]) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            LogTap.shared.note("[PiP] possible=\(possible)")
            Task { @MainActor [weak self] in self?.onPossibleChanged?(possible) }
        }
    }

    func start() { controller?.startPictureInPicture() }
    func stop() { controller?.stopPictureInPicture() }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        sourceView.playerLayer.videoGravity = gravity
    }
}

// @preconcurrency: AVKit delivers these on the main thread; the MainActor-isolated methods keep willStart
// synchronous so pipActive is set BEFORE the handoff dismiss runs (same ordering contract as the iOS
// AVKit delegate), and the restore completion crosses without a Sendable fight.
extension PlayerPiPController: @preconcurrency AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] willStart")
        onWillStart?()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] didStart")
        onDidStart?()
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        LogTap.shared.note("[PiP] failedToStart: \(error.localizedDescription)")
        onFailedToStart?(error)
    }

    func pictureInPictureController(
        _ c: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        LogTap.shared.note("[PiP] restore requested")
        onRestoreRequested?(completionHandler)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        LogTap.shared.note("[PiP] didStop")
        onDidStop?()
    }
}
#endif
