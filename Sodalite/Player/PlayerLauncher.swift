import SwiftUI
import UIKit

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
    /// Forwarded to PlayerViewModel so the version picker's choice wins over
    /// the default-first source. Nil keeps the previous behavior.
    var preferredMediaSourceID: String?
    /// Forwarded to PlayerViewModel to start a shuffle / play queue.
    /// Empty (the default) keeps ordinary single-item playback.
    var playQueue: [JellyfinItem] = []
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
                cachedPlaybackInfo: cachedPlaybackInfo,
                preferredMediaSourceID: preferredMediaSourceID,
                playQueue: playQueue
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
    /// Guards the live-player present retry loop against duplicate launches
    /// while it polls for the info sheet to finish dismissing.
    var pendingLivePresent = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}
