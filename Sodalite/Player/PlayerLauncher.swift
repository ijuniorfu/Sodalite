import SwiftUI
import UIKit

// MARK: - Player Launcher (UIKit modal presentation)

/// Presents PlayerHostController as a UIKit modal (NOT SwiftUI
/// fullScreenCover, which on tvOS intercepts Menu at the presentation level so
/// child-VC press handlers / .onExitCommand never fire).
struct PlayerLauncher: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let item: JellyfinItem?
    let startFromBeginning: Bool
    let playbackService: JellyfinPlaybackServiceProtocol
    let userID: String
    let preferences: PlaybackPreferences
    var cachedPlaybackInfo: PlaybackInfoResponse?
    /// Version picker's choice; nil = default-first source.
    var preferredMediaSourceID: String?
    /// Shuffle / play queue; empty = single-item playback.
    var playQueue: [JellyfinItem] = []
    /// Overlay tint, threaded through because WindowGroup `.tint(...)` doesn't
    /// cross into the UIKit modal; nil = asset-catalog default.
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

/// Invisible host VC: sits in the window hierarchy so UIKit present() works.
final class PlayerLauncherHostVC: UIViewController {
    /// Guards the live-player present retry loop against duplicate launches.
    var pendingLivePresent = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }
}
