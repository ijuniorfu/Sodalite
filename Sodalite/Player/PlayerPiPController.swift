#if os(iOS)
import AVKit

/// Manual PiP trigger for the touch player's PiP button. Auto-PiP (swipe-Home) is owned by the
/// AVPlayerViewController itself (allowsPictureInPicturePlayback + canStartPictureInPictureAutomaticallyFromInline);
/// this drives the same system PiP on demand over the AVKit render layer (native backend only). The
/// background-survival + restore lifecycle lives in PlayerHostController (pipActive guard, keep-presented,
/// resume-on-return), so this stays a thin start/stop.
@MainActor
final class PlayerPiPController {
    private var controller: AVPictureInPictureController?

    /// (Re)bind to the live AVKit render layer; called on each native-player rebind.
    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            controller = nil
            return
        }
        controller = AVPictureInPictureController(playerLayer: layer)
    }

    func detach() { controller = nil }

    func toggle() {
        guard let controller, controller.isPictureInPicturePossible else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }
}
#endif
