#if os(iOS)
import AVKit

/// Owns an AVPictureInPictureController over the AVKit render layer so the touch player can offer a
/// manual PiP button plus auto-PiP on backgrounding. Only the native AVPlayer backend has an
/// AVPlayerLayer; the SW-decoder (dav1d/VP9) path renders off-screen with no layer, so PiP is
/// unavailable there and the host never attaches.
@MainActor
final class PlayerPiPController {
    private var controller: AVPictureInPictureController?

    /// (Re)build the controller over the given layer. Called on each native-player rebind (the AVKit
    /// render layer is recreated on reloads, e.g. an audio-track switch), so the controller always
    /// tracks the live layer.
    func attach(to layer: AVPlayerLayer) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            controller = nil
            return
        }
        controller = AVPictureInPictureController(playerLayer: layer)
        // Auto-PiP when the app is backgrounded mid-playback (the standard iOS PiP gesture).
        controller?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    func detach() {
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        controller = nil
    }

    /// Toggle PiP from the manual button; a no-op while PiP is not yet possible (layer not ready).
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
